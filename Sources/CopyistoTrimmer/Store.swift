import AppKit
import ImageIO
import Observation

@MainActor @Observable
final class Store {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]

    private(set) var folder: URL?
    private(set) var images: [String] = []
    private(set) var trims = TrimsFile()
    var current: String? {
        didSet { if current != oldValue { selectedBox = nil } }
    }
    var selectedBox: Int?
    var format: ExportFormat {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "format") }
    }
    var isPickingFolder = false
    var showsInspector: Bool {
        didSet { UserDefaults.standard.set(showsInspector, forKey: "showsInspector") }
    }
    /// The inspector field being typed in, mirrored from its focus; nil gives the keys back to the canvas.
    var editing: InspectorField?
    /// Tags offered while typing: those used in this folder, then the server's from `.copyisto-tags.json`.
    private(set) var tagUsage: [String] = []
    /// 1 fits the page to the window; kept across pages so a zoomed-in pass over a notebook stays zoomed in.
    private(set) var zoom: CGFloat = 1
    private(set) var exportProgress: (done: Int, total: Int)?
    var exportSummary: ExportSummary?
    var error: String?

    let previews = PreviewCache()
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    /// The key of the last edit pushed onto the undo stack; a note typed letter by letter is one undo step.
    private var lastUndoKey: String?

    /// The whole file, since folder tags belong to no page; it is small, and copies share their storage.
    private struct Snapshot {
        let image: String?
        let trims: TrimsFile
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

    /// Opens a folder of scans; a dropped file opens its folder with that file selected.
    func open(_ url: URL) {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let folder = isFolder ? url : url.deletingLastPathComponent()
        do {
            // Load first: if the file is unreadable we must not open the folder, or the next autosave would overwrite it.
            let trims = try TrimsFile.load(from: folder)
            self.folder = folder
            self.trims = trims
            images = try listImages(in: folder)
            undoStack.removeAll()
            redoStack.removeAll()
            lastUndoKey = nil
            previews.removeAll()
            tagUsage = Tags.usage(in: folder)
            current = isFolder ? images.first : url.lastPathComponent
            UserDefaults.standard.set(folder.path, forKey: "folder")
        } catch {
            self.error = "Nie udało się otworzyć folderu „\(folder.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    /// Picks up pages scanned while the app was in the background, and tags from a fresh `copyisto raw pull`.
    func refreshImages() {
        guard let folder else { return }
        tagUsage = Tags.usage(in: folder)
        guard let names = try? listImages(in: folder), names != images else { return }
        images = names
        if let current, !names.contains(current) { self.current = names.first }
    }

    private func listImages(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { !$0.hasPrefix(".") && Self.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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

    func boxes(for image: String) -> [Box] {
        trims.images[image]?.boxes ?? []
    }

    var totalBoxes: Int {
        images.reduce(0) { $0 + boxes(for: $1).count }
    }

    /// True when the page on disk is not the size the boxes were drawn on, e.g. after a re-scan.
    func sizeChanged(_ image: String, actual: CGSize) -> Bool {
        guard let stored = trims.images[image], !stored.boxes.isEmpty else { return false }
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
        trims.images[image]?.rotation ?? 0
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
        // A page without an entry yet gets its real size, never 0x0, since the CLI reads it.
        let before = trims.images[image] ?? ImageTrims(size: imageSize ?? pixelSize(of: image) ?? .zero)
        var page = before
        // Editing a page confirms its current size.
        if let imageSize { page.width = Int(imageSize.width); page.height = Int(imageSize.height) }
        edit(&page)
        guard page != before else { return }
        var after = trims
        after.images[image] = page
        commit(after, image: image, undoKey: undoKey)
    }

    private func commit(_ after: TrimsFile, image: String?, undoKey: String?) {
        guard after != trims else { return }
        if undoKey == nil || undoKey != lastUndoKey {
            undoStack.append(Snapshot(image: image, trims: trims))
        }
        lastUndoKey = undoKey
        redoStack.removeAll()
        trims = after
        save()
    }

    // MARK: Tags and notes

    /// Opens the inspector on a field, so describing hundreds of boxes needs no mouse.
    func describe(_ field: InspectorField) {
        showsInspector = true
        editing = field
    }

    var folderTags: [String] { trims.tags ?? [] }

    func setFolderTags(_ tags: [String]) {
        var after = trims
        after.tags = Self.stored(tags)
        commit(after, image: nil, undoKey: nil)
    }

    func pageTags(_ image: String) -> [String] { trims.images[image]?.tags ?? [] }
    func pageNote(_ image: String) -> String { trims.images[image]?.note ?? "" }

    func setPageTags(_ tags: [String], on image: String) {
        change(image, imageSize: nil) { $0.tags = Self.stored(tags) }
    }

    /// Cut so that, joined with the longest box note on the page, it stays within the CLI's limit.
    func setPageNote(_ note: String, on image: String) {
        let room = boxes(for: image).map { Tags.noteRoom(besides: $0.note) }.min() ?? Tags.maxNote
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
        let room = Tags.noteRoom(besides: pageNote(image))
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

    /// Every tag a crop from this box gets from the trimmer, in the CLI's order.
    func cropTags(box: Box, on image: String) -> [String] {
        Tags.merged(trims.tags, trims.images[image]?.tags, box.tags)
    }

    /// Tags used anywhere in this folder, most used first, then the server's.
    var tagSuggestions: [String] {
        var counts: [String: Int] = [:]
        let pages = trims.images.values
        for tag in (trims.tags ?? []) + pages.flatMap({ ($0.tags ?? []) + $0.boxes.flatMap { $0.tags ?? [] } }) {
            counts[tag, default: 0] += 1
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
        save()
        return replaced
    }

    private func save() {
        guard let folder else { return }
        do {
            try trims.save(to: folder)
        } catch {
            self.error = "Nie udało się zapisać \(TrimsFile.fileName): \(error.localizedDescription)"
        }
    }

    // MARK: Export

    var isExporting: Bool { exportProgress != nil }

    func export() async {
        guard let folder, !isExporting else { return }
        exportProgress = (0, 0)
        defer { exportProgress = nil }
        do {
            exportSummary = try await Exporter.run(
                folder: folder, images: images, trims: trims.images, format: format
            ) { done, total in
                self.exportProgress = (done, total)
            }
        } catch {
            self.error = "Eksport nie powiódł się: \(error.localizedDescription)"
        }
    }

    func revealExport() {
        guard let folder = exportSummary?.folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
