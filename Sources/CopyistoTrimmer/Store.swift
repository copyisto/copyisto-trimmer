import AppKit
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
    /// 1 fits the page to the window; kept across pages so a zoomed-in pass over a notebook stays zoomed in.
    private(set) var zoom: CGFloat = 1
    private(set) var exportProgress: (done: Int, total: Int)?
    var exportSummary: ExportSummary?
    var error: String?

    let previews = PreviewCache()
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    private struct Snapshot {
        let image: String
        let trims: ImageTrims
    }

    init() {
        format = UserDefaults.standard.string(forKey: "format").flatMap(ExportFormat.init) ?? .png
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
            previews.removeAll()
            current = isFolder ? images.first : url.lastPathComponent
            UserDefaults.standard.set(folder.path, forKey: "folder")
        } catch {
            self.error = "Nie udało się otworzyć folderu „\(folder.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    /// Picks up pages scanned while the app was in the background.
    func refreshImages() {
        guard let folder, let names = try? listImages(in: folder), names != images else { return }
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
            trims.boxes[index] = Box(id: id, rect: rect)
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
            trims.boxes = trims.boxes.map { box in
                let rect = box.rect
                let centre = rotated(CGPoint(x: rect.midX, y: rect.midY), by: delta, in: imageSize)
                let shifted = CGSize(width: centre.x - rect.midX, height: centre.y - rect.midY)
                return Box(id: box.id, rect: moved(rect, by: shifted, within: imageSize))
            }
        }
    }

    /// `to` gets the current angle; the page size comes from its preview, which is cached by the time anyone presses a key.
    func rotateCurrent(to angle: @escaping (Double) -> Double) {
        guard let current, let url = url(for: current) else { return }
        Task {
            guard let preview = await previews.preview(for: url) else { return }
            setRotation(angle(rotation(of: current)), on: current, imageSize: preview.pixelSize)
        }
    }

    func rotateCurrent(by delta: Double) { rotateCurrent { $0 + delta } }
    func resetRotation() { rotateCurrent { _ in 0 } }

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

    /// Every edit goes through here, so each one is undoable and saved straight away.
    private func change(_ image: String, imageSize: CGSize?, _ edit: (inout ImageTrims) -> Void) {
        let before = trims.images[image] ?? ImageTrims(size: imageSize ?? .zero)
        var after = before
        // Editing a page confirms its current size.
        if let imageSize { after.width = Int(imageSize.width); after.height = Int(imageSize.height) }
        edit(&after)
        guard after != before else { return }
        undoStack.append(Snapshot(image: image, trims: before))
        redoStack.removeAll()
        trims.images[image] = after
        save()
    }

    // MARK: Undo

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(restore(snapshot))
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(restore(snapshot))
    }

    /// Applies a snapshot and returns the state it replaced.
    private func restore(_ snapshot: Snapshot) -> Snapshot {
        let replaced = trims.images[snapshot.image] ?? snapshot.trims
        trims.images[snapshot.image] = snapshot.trims
        current = snapshot.image
        selectedBox = nil
        save()
        return Snapshot(image: snapshot.image, trims: replaced)
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
