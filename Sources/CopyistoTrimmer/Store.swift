import AppKit
import CryptoKit
import ImageIO
import Observation

/// One folder of scans, with its own `.trims/` for its boxes and crops.
struct Notebook: Equatable, Identifiable {
    /// Relative to the opened folder: `01`, or empty when the opened folder is the notebook itself.
    let path: String
    /// The folder's name: `01`, or `nowy` for a notebook without a number yet.
    let name: String
    /// Its pages as the app names them: paths relative to the opened folder, so `01/skan_001.png` and `02/skan_001.png` differ.
    var images: [String]

    var id: String { path }
}

@MainActor @Observable
final class Store {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]

    /// The folder as opened: a submission (`copyisto init`), one of its notebooks, or any folder of scans.
    private(set) var folder: URL?
    private(set) var submission: Submission?
    /// True when `folder` is the submission itself, with a folder per notebook.
    private(set) var isSubmissionRoot = false
    private(set) var notebooks: [Notebook] = []
    /// Every page, notebook after notebook, in the order of the list.
    private(set) var images: [String] = []
    /// Each notebook's file, by `Notebook.path`.
    private(set) var trims: [String: TrimsFile] = [:]
    /// The submission's `.copyisto/description.json`; empty outside a submission.
    private(set) var description = Description()
    /// Files at the top of a submission, which belong to no notebook, so neither the CLI nor the app uses them.
    private(set) var strayFiles: [String] = []
    /// Old trimmer files left beside a notebook's `.trims/`, which nothing uses any more, e.g. `01/trims.copyisto.json`.
    private(set) var leftovers: [String] = []
    var current: String? {
        didSet {
            guard current != oldValue else { return }
            selectedBox = nil
            if let current { collapsed.remove(notebookPath(of: current)) }
            remember()
        }
    }
    var selectedBox: Int?
    /// Notebook sections folded in the list, by `Notebook.path`.
    var collapsed: Set<String> = [] {
        didSet { remember() }
    }
    var format: ExportFormat {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "format") }
    }
    var isPickingFolder = false
    var showsLabs = false
    let labs = Labs()
    var showsInspector: Bool {
        didSet { UserDefaults.standard.set(showsInspector, forKey: "showsInspector") }
    }
    /// The inspector field being typed in, mirrored from its focus; nil gives the keys back to the canvas.
    var editing: InspectorField?
    /// Tags offered while typing: those used in the open notebooks, then the server's from the CLI's list.
    private(set) var tagUsage: [String] = []
    /// 1 fits the page to the window; kept across pages so a zoomed-in pass over a notebook stays zoomed in.
    private(set) var zoom: CGFloat = 1
    private(set) var exportProgress: (done: Int, total: Int)?
    var exportSummary: ExportSummary?
    /// A description field someone else changed since the app read it, which the person picks between.
    var descriptionConflict: DescriptionConflict?
    var error: String?

    let previews = PreviewCache()
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var watcher: FolderWatcher?
    /// Notebooks whose last save failed because their folder was gone, e.g. renamed by `copyisto push` a moment before.
    private var unsaved: Set<String> = []
    /// Set while a folder opens, so its remembered page is not overwritten by the one being left.
    private var isOpening = false

    /// The key of the last edit pushed onto the undo stack; a note typed letter by letter is one undo step.
    private var lastUndoKey: String?

    /// Every notebook's file, since its tags belong to no page; they are small, and copies share their storage.
    private struct Snapshot {
        let image: String?
        let trims: [String: TrimsFile]
    }

    init() {
        format = UserDefaults.standard.string(forKey: "format").flatMap(ExportFormat.init) ?? .png
        showsInspector = UserDefaults.standard.object(forKey: "showsInspector") as? Bool ?? true
        // A menu item carries one shortcut; this adds ⌘= next to ⌘+, as in Preview and Safari.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                event.charactersIgnoringModifiers == "="
            else { return event }
            MainActor.assumeIsolated { self?.zoomIn() }
            return nil
        }
        if let path = UserDefaults.standard.string(forKey: "folder"),
            FileManager.default.fileExists(atPath: path)
        {
            open(URL(filePath: path, directoryHint: .isDirectory))
        }
    }

    // MARK: Folder

    /// What a folder holds: its notebooks, their files, and the files that belong to none.
    private struct Contents {
        var notebooks: [Notebook] = []
        var trims: [String: TrimsFile] = [:]
        var strayFiles: [String] = []
        var leftovers: [String] = []
    }

    /// Opens a submission, a notebook or any folder of scans; a dropped file opens its folder with that file selected.
    func open(_ url: URL) {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let folder = (isFolder ? url : url.deletingLastPathComponent()).standardizedFileURL
        let found = Submission.of(folder)
        do {
            // Load first: if a file is unreadable we must not open the folder, or the next autosave would overwrite it.
            let contents = try read(folder, isRoot: found?.isRoot == true, migrating: true)
            isOpening = true
            defer { isOpening = false }
            self.folder = folder
            submission = found?.submission
            isSubmissionRoot = found?.isRoot == true
            apply(contents)
            undoStack.removeAll()
            redoStack.removeAll()
            lastUndoKey = nil
            unsaved.removeAll()
            previews.removeAll()
            loadDescription()
            collapsed = Set(UserDefaults.standard.dictionary(forKey: "collapsed")?[folder.path] as? [String] ?? [])
            let remembered = UserDefaults.standard.dictionary(forKey: "page")?[folder.path] as? String
            let dropped = isFolder ? nil : images.first { fileName(of: $0) == url.lastPathComponent }
            current = dropped ?? remembered.flatMap { images.contains($0) ? $0 : nil } ?? images.first
            UserDefaults.standard.set(folder.path, forKey: "folder")
            watch()
        } catch {
            self.error = "Nie udało się otworzyć folderu „\(folder.lastPathComponent)”: \(error.localizedDescription)"
        }
        remember()
    }

    /// Reads the folder again after something outside the app changed it: `copyisto pull` adds pages and notebooks
    /// and rewrites the description, and `copyisto push` renames a new notebook's folder to its number.
    func reload() {
        guard let folder else { return }
        if !FileManager.default.fileExists(atPath: folder.path) { return relocate() }
        guard var contents = try? read(folder, isRoot: isSubmissionRoot, migrating: false) else { return }
        let before = notebooks
        // A notebook folder that vanished as one with the same pages appeared was renamed.
        var renamed: [String: String] = [:]
        for old in before where !contents.notebooks.contains(where: { $0.path == old.path }) {
            let names = Set(old.images.map(fileName(of:)))
            let new = contents.notebooks.first { new in
                !before.contains { $0.path == new.path } && Set(new.images.map(fileName(of:))) == names
            }
            if let new { renamed[old.path] = new.path }
        }
        var changedOnDisk = false
        for (path, file) in contents.trims {
            guard let mine = trims[renamed.first { $0.value == path }?.key ?? path], mine != file else { continue }
            if let old = renamed.first(where: { $0.value == path })?.key, unsaved.remove(old) != nil {
                // Saved where the folder used to be, a moment too late: the boxes go to its new place.
                contents.trims[path] = mine
                try? mine.save(to: notebookURL(path))
            } else {
                changedOnDisk = true
            }
        }
        let structural = Set(before.map(\.path)) != Set(contents.notebooks.map(\.path))
        let selected = selectedBox
        let page = current.map { image in
            renamed[notebookPath(of: image)].map { join($0, fileName(of: image)) } ?? image
        }
        apply(contents)
        // Undoing would put back what someone else's pull just changed, or point at a folder that is gone.
        if changedOnDisk || structural {
            undoStack.removeAll()
            redoStack.removeAll()
            lastUndoKey = nil
        }
        collapsed = Set(collapsed.map { renamed[$0] ?? $0 })
        for (old, new) in renamed {
            exported[notebookURL(new).path] = exported.removeValue(forKey: notebookURL(old).path)
        }
        if let page, images.contains(page) {
            current = page
            selectedBox = selected.flatMap { box($0, on: page) == nil ? nil : $0 }
        } else if current.map(images.contains) != true {
            current = images.first
        }
        loadDescription()
        if structural { watch() }
    }

    /// A notebook opened on its own whose folder `copyisto push` renamed to its new number: opens it there.
    private func relocate() {
        guard let submission, !isSubmissionRoot else { return }
        let names = Set(images.map(fileName(of:)))
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: submission.root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        guard let moved = folders.first(where: { isDirectory($0) && Set((try? listImages(in: $0)) ?? []) == names }) else { return }
        if unsaved.contains(""), let mine = trims[""] { try? mine.save(to: moved) }
        let page = current.map(fileName(of:))
        open(moved)
        if let page, images.contains(page) { current = page }
    }

    private func read(_ folder: URL, isRoot: Bool, migrating: Bool) throws -> Contents {
        var contents = Contents()
        if isRoot {
            let entries = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            // An old layout's crops folder left at the top by mistake is no notebook.
            let ignored = Set(TrimsLocation.legacyNames.map(\.1))
            let names = entries.filter(isDirectory).map(\.lastPathComponent).filter { !ignored.contains($0) }
                .sorted(by: Submission.notebookOrder)
            contents.strayFiles = entries.filter { !isDirectory($0) }.map(\.lastPathComponent)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for name in names {
                try load(folder.appending(path: name), path: name, name: name, into: &contents, migrating: migrating)
            }
        } else {
            try load(folder, path: "", name: folder.lastPathComponent, into: &contents, migrating: migrating)
        }
        return contents
    }

    private func load(_ url: URL, path: String, name: String, into contents: inout Contents, migrating: Bool) throws {
        do {
            if migrating { TrimsLocation.migrate(in: url) }
            contents.trims[path] = try TrimsFile.load(from: url)
            contents.leftovers += TrimsLocation.leftovers(in: url).map { join(path, $0) }
            let images = try listImages(in: url).map { join(path, $0) }
            contents.notebooks.append(Notebook(path: path, name: name, images: images))
        } catch where !path.isEmpty {
            throw NotebookError(name: name, underlying: error)
        }
    }

    private func apply(_ contents: Contents) {
        notebooks = contents.notebooks
        trims = contents.trims
        strayFiles = contents.strayFiles
        leftovers = contents.leftovers
        images = contents.notebooks.flatMap(\.images)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func listImages(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { !$0.hasPrefix(".") && Self.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Watches the folder, and the submission's `.copyisto/` above a notebook opened on its own, for the CLI's changes.
    private func watch() {
        guard let folder else { return }
        var paths = [folder]
        if let submission, !isSubmissionRoot { paths.append(submission.root.appending(path: Submission.directory)) }
        watcher = FolderWatcher(paths: paths) { [weak self] in self?.reload() }
    }

    /// The open folder and, per folder, the page and the folded sections, so the app opens where the work stopped.
    private func remember() {
        guard let folder, !isOpening else { return }
        for (key, value) in [("page", current as Any?), ("collapsed", collapsed.sorted() as Any?)] {
            var saved = UserDefaults.standard.dictionary(forKey: key) ?? [:]
            saved[folder.path] = value
            UserDefaults.standard.set(saved, forKey: key)
        }
    }

    // MARK: Pages and notebooks

    func notebookPath(of image: String) -> String { (image as NSString).deletingLastPathComponent }
    func fileName(of image: String) -> String { (image as NSString).lastPathComponent }
    private func join(_ notebook: String, _ name: String) -> String { notebook.isEmpty ? name : "\(notebook)/\(name)" }

    func notebookURL(_ path: String) -> URL {
        guard let folder else { return URL(filePath: "/") }
        return path.isEmpty ? folder : folder.appending(path: path, directoryHint: .isDirectory)
    }

    func notebook(of image: String) -> Notebook? {
        notebooks.first { $0.path == notebookPath(of: image) }
    }

    /// The notebook's number in its submission (`01`), or nil outside a submission and for a new notebook.
    func number(of notebook: Notebook) -> String? {
        submission == nil ? nil : Submission.number(of: notebook.name)
    }

    /// „M4K-V-01” for a notebook of a submission, the folder's name otherwise.
    func title(of notebook: Notebook) -> String {
        submission?.title(of: notebook.name) ?? notebook.name
    }

    /// The window's title: the submission's code, a notebook's ID, or the folder's name.
    var title: String {
        guard let folder else { return "Copyisto Trimmer" }
        guard let submission else { return folder.lastPathComponent }
        return isSubmissionRoot ? submission.code : submission.title(of: folder.lastPathComponent)
    }

    func url(for image: String) -> URL? {
        folder?.appending(path: image)
    }

    func canStep(_ delta: Int) -> Bool {
        guard let current, let index = images.firstIndex(of: current) else { return false }
        return images.indices.contains(index + delta)
    }

    func step(_ delta: Int) {
        guard let current, let index = images.firstIndex(of: current) else { return }
        self.current = images[min(max(index + delta, 0), images.count - 1)]
    }

    /// Decodes the current page and its neighbours ahead of time.
    func prefetch() {
        guard let current, let index = images.firstIndex(of: current) else { return }
        let range = max(index - 1, 0)...min(index + 2, images.count - 1)
        previews.keep(only: images[range].compactMap(url(for:)))
    }

    // MARK: Zoom

    static let zoomSteps: [CGFloat] = [1, 1.5, 2, 3, 4, 6, 8]

    func zoomIn() { zoom = Self.zoomSteps.first { $0 > zoom + 0.01 } ?? Self.zoomSteps.last! }
    func zoomOut() { zoom = Self.zoomSteps.last { $0 < zoom - 0.01 } ?? 1 }
    func zoomToFit() { zoom = 1 }
    func setZoom(_ value: CGFloat) { zoom = min(max(value, 1), Self.zoomSteps.last!) }

    // MARK: Boxes

    private func page(_ image: String) -> ImageTrims? {
        trims[notebookPath(of: image)]?.images[fileName(of: image)]
    }

    func boxes(for image: String) -> [Box] {
        page(image)?.boxes ?? []
    }

    var totalBoxes: Int {
        images.reduce(0) { $0 + boxes(for: $1).count }
    }

    /// True when the page on disk is not the size the boxes were drawn on, e.g. after a re-scan.
    func sizeChanged(_ image: String, actual: CGSize) -> Bool {
        guard let stored = page(image), !stored.boxes.isEmpty else { return false }
        return stored.size != actual
    }

    func addBox(_ rect: CGRect, on image: String, imageSize: CGSize) {
        var id: Int?
        change(image, imageSize: imageSize) { id = $0.add(rect) }
        selectedBox = id
    }

    func updateBox(_ id: Int, rect: CGRect, on image: String, imageSize: CGSize) {
        change(image, imageSize: imageSize) { trims in
            guard let index = trims.boxes.firstIndex(where: { $0.id == id }) else { return }
            trims.boxes[index].rect = rect
        }
    }

    // MARK: Rotation

    /// A press of the rotate buttons; fine enough to level a staff line across the whole page.
    static let rotationStep = 0.1

    func rotation(of image: String) -> Double {
        page(image)?.rotation ?? 0
    }

    /// Turns the page and carries its boxes along, so each still frames what it was drawn around.
    func setRotation(_ degrees: Double, on image: String, imageSize: CGSize) {
        let degrees = min(max((degrees * 100).rounded() / 100, -Straighten.maxAngle), Straighten.maxAngle)
        change(image, imageSize: imageSize) { trims in
            let delta = degrees - (trims.rotation ?? 0)
            trims.rotation = degrees == 0 ? nil : degrees
            for index in trims.boxes.indices {
                let rect = trims.boxes[index].rect
                let centre = rotated(CGPoint(x: rect.midX, y: rect.midY), by: delta, in: imageSize)
                let shifted = CGSize(width: centre.x - rect.midX, height: centre.y - rect.midY)
                trims.boxes[index].rect = moved(rect, by: shifted, within: imageSize)
            }
        }
    }

    func rotateCurrent(by delta: Double) {
        guard let current, let size = pixelSize(of: current) else { return }
        setRotation(rotation(of: current) + delta, on: current, imageSize: size)
    }

    func resetRotation() {
        guard let current, let size = pixelSize(of: current) else { return }
        setRotation(0, on: current, imageSize: size)
    }

    /// The page's size from its file header, which takes a millisecond, without decoding it.
    func pixelSize(of image: String) -> CGSize? {
        guard let url = url(for: image), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    private(set) var isStraightening = false

    /// Levels the current page by its staff lines; runs on the preview, so it takes a fraction of a second.
    func straightenCurrent() async {
        guard let current, let url = url(for: current), !isStraightening else { return }
        isStraightening = true
        defer { isStraightening = false }
        guard let preview = await previews.preview(for: url) else { return }
        let image = preview.image
        let angle = await Task.detached(priority: .userInitiated) { Straighten.angle(of: image) }.value
        setRotation(angle, on: current, imageSize: preview.pixelSize)
    }

    func deleteSelected() {
        guard let current, let id = selectedBox else { return }
        deleteBox(id, on: current)
    }

    func deleteBox(_ id: Int, on image: String) {
        change(image, imageSize: nil) { $0.boxes.removeAll { $0.id == id } }
        if selectedBox == id { selectedBox = nil }
    }

    /// Every page edit goes through here, so each one is undoable and saved straight away.
    private func change(_ image: String, imageSize: CGSize?, undoKey: String? = nil, _ edit: (inout ImageTrims) -> Void) {
        let notebook = notebookPath(of: image), name = fileName(of: image)
        // A page without an entry yet gets its real size, never 0x0, since the CLI reads it.
        let before = trims[notebook]?.images[name] ?? ImageTrims(size: imageSize ?? pixelSize(of: image) ?? .zero)
        var page = before
        // Editing a page confirms its current size.
        if let imageSize { page.width = Int(imageSize.width); page.height = Int(imageSize.height) }
        edit(&page)
        guard page != before else { return }
        var after = trims
        after[notebook, default: TrimsFile()].images[name] = page
        commit(after, image: image, undoKey: undoKey)
    }

    private func commit(_ after: [String: TrimsFile], image: String?, undoKey: String?) {
        guard after != trims else { return }
        if undoKey == nil || undoKey != lastUndoKey {
            undoStack.append(Snapshot(image: image, trims: trims))
        }
        lastUndoKey = undoKey
        redoStack.removeAll()
        let before = trims
        trims = after
        save(changedFrom: before)
    }

    // MARK: Tags and notes

    /// Opens the inspector on a field, so describing hundreds of boxes needs no mouse.
    func describe(_ field: InspectorField) {
        showsInspector = true
        editing = field
    }

    /// Tags in a notebook's trimmer file for every crop from it: the folder's tags outside a submission.
    func notebookTags(_ notebook: String) -> [String] { trims[notebook]?.tags ?? [] }

    func setNotebookTags(_ tags: [String], of notebook: String) {
        var after = trims
        after[notebook, default: TrimsFile()].tags = Self.stored(tags)
        commit(after, image: nil, undoKey: nil)
    }

    func pageTags(_ image: String) -> [String] { page(image)?.tags ?? [] }
    func pageNote(_ image: String) -> String { page(image)?.note ?? "" }

    func setPageTags(_ tags: [String], on image: String) {
        change(image, imageSize: nil) { $0.tags = Self.stored(tags) }
    }

    /// Cut so that, joined with the file's note and the longest box note on the page, it stays within the CLI's limit.
    func setPageNote(_ note: String, on image: String) {
        let file = meta(of: image).note
        let room = boxes(for: image).map { Tags.noteRoom(besides: Tags.joinedNote(file, $0.note)) }.min()
            ?? Tags.noteRoom(besides: file)
        change(image, imageSize: nil, undoKey: "note:\(image)") {
            $0.note = Self.stored(Tags.truncated(note, to: room))
        }
    }

    func box(_ id: Int, on image: String) -> Box? {
        boxes(for: image).first { $0.id == id }
    }

    func setBoxTags(_ tags: [String], box id: Int, on image: String) {
        editBox(id, on: image) { $0.tags = Self.stored(tags) }
    }

    func setBoxNote(_ note: String, box id: Int, on image: String) {
        let room = Tags.noteRoom(besides: Tags.joinedNote(meta(of: image).note, pageNote(image)))
        editBox(id, on: image, undoKey: "note:\(image):\(id)") {
            $0.note = Self.stored(Tags.truncated(note, to: room))
        }
    }

    private func editBox(_ id: Int, on image: String, undoKey: String? = nil, _ edit: (inout Box) -> Void) {
        change(image, imageSize: nil, undoKey: undoKey) { trims in
            guard let index = trims.boxes.firstIndex(where: { $0.id == id }) else { return }
            edit(&trims.boxes[index])
        }
    }

    /// Tags a crop from this page gets before the box's own: the file's description, then the notebook's and the page's
    /// in its trimmer file, in the order `copyisto push` joins them.
    func inheritedTags(of image: String) -> [String] {
        Tags.merged(meta(of: image).tags, notebookTags(notebookPath(of: image)), pageTags(image))
    }

    /// Every tag a crop from this box gets, in the CLI's order.
    func cropTags(box: Box, on image: String) -> [String] {
        Tags.merged(inheritedTags(of: image), box.tags)
    }

    /// A crop's note as the CLI writes it: the file's, the page's and the box's, one per line.
    func cropNote(box: Box?, on image: String) -> String {
        Tags.joinedNote(meta(of: image).note, pageNote(image), box?.note)
    }

    /// Tags used anywhere in the open notebooks, most used first, then the server's.
    var tagSuggestions: [String] {
        var counts: [String: Int] = [:]
        for file in trims.values {
            let pages = file.images.values
            for tag in (file.tags ?? []) + pages.flatMap({ ($0.tags ?? []) + $0.boxes.flatMap { $0.tags ?? [] } }) {
                counts[tag, default: 0] += 1
            }
        }
        let used = counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
        return Tags.merged(used, tagUsage)
    }

    /// Empty lists and notes are left out of the file, as a level page leaves out `rotation`.
    private static func stored(_ tags: [String]) -> [String]? {
        let tags = Tags.merged(tags.compactMap(Tags.validated))
        return tags.isEmpty ? nil : tags
    }

    private static func stored(_ note: String) -> String? {
        note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
    }

    // MARK: Description

    /// Where a page's own part of the description is, or nil when its notebook has no number yet to file it under.
    func descriptionLevel(of image: String) -> [String]? {
        notebook(of: image).flatMap(number(of:)).map { Description.file(fileName(of: image), in: $0) }
    }

    func descriptionLevel(of notebook: Notebook) -> [String]? {
        number(of: notebook).map(Description.notebook)
    }

    /// The page's description as it applies; a new notebook's files get only what is said for the whole submission.
    func meta(of image: String) -> Description.Meta {
        guard submission != nil else { return Description.Meta() }
        return description.meta(of: fileName(of: image), in: notebook(of: image).flatMap(number(of:)))
    }

    /// Sets one field of the shared description and writes it, as `copyisto describe` would; `copyisto push` sends it.
    /// The file is read again first, since a pull may have changed it, and keeps everything this edit does not touch.
    func setDescription(_ field: Description.Field, _ value: Any?, at level: [String], force: Bool = false) {
        guard let submission else { return }
        let key = level + field.key
        let mine = Description.stored(field, value)
        do {
            let disk = try Description.read(from: submission.descriptionURL)
            let theirs = disk.value(at: key)
            guard !Description.same(theirs, mine) else { description = disk; return }
            // Changed in the file since the app read it, and not to what is typed now: the person decides.
            if !force, !Description.same(theirs, description.value(at: key)) {
                description = disk
                descriptionConflict = DescriptionConflict(field: field, level: level, mine: mine)
                return
            }
            let after = disk.setting(mine, at: key)
            try after.write(to: submission.descriptionURL)
            description = after
        } catch {
            self.error = "Nie udało się zapisać opisu w \(Submission.directory)/description.json: \(error.localizedDescription)"
        }
    }

    /// Keeps the person's value over the one in the file.
    func keepMine(_ conflict: DescriptionConflict) {
        setDescription(conflict.field, conflict.mine, at: conflict.level, force: true)
    }

    /// The file's note can be no longer than any crop from the page leaves room for.
    func setFileNote(_ note: String, on image: String) {
        guard let level = descriptionLevel(of: image) else { return }
        let page = pageNote(image)
        let room = boxes(for: image).map { Tags.noteRoom(besides: Tags.joinedNote(page, $0.note)) }.min()
            ?? Tags.noteRoom(besides: page)
        setDescription(.note, Tags.truncated(note, to: room), at: level)
    }

    private func loadDescription() {
        // A file mid-write or broken by hand keeps what was shown; the CLI reports the problem itself.
        if let submission {
            if let read = try? Description.read(from: submission.descriptionURL) { description = read }
        } else {
            description = Description()
        }
        tagUsage = Tags.usage(from: usageFiles)
    }

    /// The server's tags in use: the submission's list, else one an older CLI left in a notebook folder.
    private var usageFiles: [URL] {
        let older = notebooks.flatMap { notebook in Tags.legacyUsageFiles.map { notebookURL(notebook.path).appending(path: $0) } }
        return (submission.map { [$0.tagsURL] } ?? []) + older
    }

    // MARK: Undo

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        // In a text field ⌘Z undoes the typing, as anywhere else on the Mac.
        if editing != nil { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil); return }
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(restore(snapshot))
    }

    func redo() {
        if editing != nil { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil); return }
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(restore(snapshot))
    }

    /// Applies a snapshot and returns the state it replaced.
    private func restore(_ snapshot: Snapshot) -> Snapshot {
        let replaced = Snapshot(image: snapshot.image, trims: trims)
        trims = snapshot.trims
        lastUndoKey = nil
        if let image = snapshot.image { current = image }
        // The selection stays while its box exists, so undoing a note keeps the inspector on that box.
        if let current, let selectedBox, box(selectedBox, on: current) == nil { self.selectedBox = nil }
        save(changedFrom: replaced.trims)
        return replaced
    }

    /// Writes the notebooks whose file changed; each box lives in its own notebook's file, never a shared one.
    private func save(changedFrom before: [String: TrimsFile]) {
        for (path, file) in trims where before[path] != file {
            let folder = notebookURL(path)
            do {
                try file.save(to: folder)
                unsaved.remove(path)
            } catch where !FileManager.default.fileExists(atPath: folder.path) {
                // Renamed under us; the reload that follows saves it in the new place.
                unsaved.insert(path)
            } catch {
                self.error = "Nie udało się zapisać ramek: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Export

    var isExporting: Bool { exportProgress != nil }

    /// Exports every notebook whose boxes changed since its last export, each into its own `.trims/crops/`.
    /// `announce` shows the summary; a push exports first and reports its own outcome instead.
    @discardableResult
    func export(announce: Bool = true) async -> Bool {
        guard !isExporting else { return false }
        let due = notebooks.filter(needsExport)
        let pages = due.map { notebook in notebook.images.filter { !boxes(for: $0).isEmpty }.count }
        let total = pages.reduce(0, +)
        exportProgress = (0, total)
        defer { exportProgress = nil }
        var summary = ExportSummary()
        var offset = 0
        do {
            for (notebook, count) in zip(due, pages) {
                let file = trims[notebook.path] ?? TrimsFile()
                let start = offset
                let result = try await Exporter.run(
                    folder: notebookURL(notebook.path), images: notebook.images.map(fileName(of:)),
                    trims: file.images, format: format
                ) { done, _ in
                    self.exportProgress = (start + done, total)
                }
                offset += count
                summary.crops += result.crops
                summary.images += result.images
                summary.folders += result.folders
                summary.notebooks.append(title(of: notebook))
                exported[notebookURL(notebook.path).path] = fingerprint(file)
            }
            if announce { exportSummary = summary }
            return true
        } catch {
            self.error = "Eksport nie powiódł się: \(error.localizedDescription)"
            return false
        }
    }

    /// True when the notebook's crops are not what its boxes would cut now: boxes moved since the last export,
    /// another format, or crops missing or left over in its `.trims/crops/`.
    func needsExport(_ notebook: Notebook) -> Bool {
        let file = trims[notebook.path] ?? TrimsFile()
        let names = notebook.images.map(fileName(of:))
        let expected = Set(names.flatMap { name -> [String] in
            guard let page = file.images[name] else { return [] }
            return page.boxes.indices.compactMap { index in
                isUsable(clamped(page.boxes[index].rect, to: page.size))
                    ? cropFileName(image: name, number: index + 1, format: format) : nil
            }
        })
        let output = TrimsLocation.crops(in: notebookURL(notebook.path))
        let listed = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
        let existing = Set(staleCrops(in: listed, images: names, keep: []))
        if expected.isEmpty, existing.isEmpty { return false }
        return expected != existing || exported[notebookURL(notebook.path).path] != fingerprint(file)
    }

    /// What decides a notebook's crops: its pages' sizes, turns and boxes, and the format.
    private func fingerprint(_ file: TrimsFile) -> String {
        let cut = file.images.mapValues { page in
            [page.width, page.height, Int(((page.rotation ?? 0) * 100).rounded())]
                + page.boxes.flatMap { [$0.x, $0.y, $0.width, $0.height] }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(cut)) ?? Data()
        return SHA256.hash(data: data + Data(format.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The fingerprint of each notebook folder's last export, by path; kept by the app, so no file is added to the folder.
    private var exported: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "exported") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "exported") }
    }

    func revealExport() {
        revealCrops(in: exportSummary?.folders ?? [])
    }

    /// The crops of the current page's notebook, or of every notebook; their folder is hidden, so this is the way in.
    func revealCrops() {
        let notebooks = current.flatMap(notebook(of:)).map { [$0] } ?? notebooks
        revealCrops(in: notebooks.map { TrimsLocation.crops(in: notebookURL($0.path)) })
    }

    var hasCrops: Bool {
        notebooks.contains { FileManager.default.fileExists(atPath: TrimsLocation.crops(in: notebookURL($0.path)).path) }
    }

    /// Selecting a crop opens Finder inside the hidden folder, where selecting the folder itself would show nothing.
    private func revealCrops(in folders: [URL]) {
        let files = FileManager.default
        let shown = folders.compactMap { folder -> URL? in
            let crops = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            return crops.min { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        if shown.isEmpty, let folder = folders.first(where: { files.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.open(folder)
        } else if !shown.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(shown)
        }
    }
}

struct DescriptionConflict {
    let field: Description.Field
    let level: [String]
    let mine: Any?

    var label: String {
        switch field {
        case .deviceType: "rodzaj urządzenia"
        case .device: "model urządzenia"
        case .dpi: "DPI"
        case .tags: "tagi"
        case .note: "uwaga"
        }
    }
}

struct NotebookError: LocalizedError {
    let name: String
    let underlying: Error

    var errorDescription: String? { "\(name)/: \(underlying.localizedDescription)" }
}

/// Calls back on the main queue a moment after anything under its paths changes, however deep.
@MainActor
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(paths: [URL], onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            MainActor.assumeIsolated { Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange() }
        }
        // ponytail: one reload per burst, 0.3 s after it, rereading every notebook's file; fine for a submission's few notebooks.
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
