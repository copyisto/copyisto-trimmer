import CoreGraphics
import Foundation

/// The boxes for one folder of scans, stored next to them as `trims.copyisto.json`.
/// The `.copyisto` suffix marks it, and the crops' folder, as Copyisto's, so they do not look like stray files to move or delete.
/// Coordinates are in pixels of the original image, like labelme, so they never depend on the window size.
struct TrimsFile: Codable, Equatable {
    static let fileName = "trims.copyisto.json"
    /// The names before, renamed when a folder opens, so a folder cut with an older build carries on where it left off.
    static let legacyNames = [("copyisto-trims.json", fileName), ("copyisto-trims", Exporter.folderName)]
    // 2 added `rotation`, 3 added `tags` and `note`.
    // Every new field needs a new version: Codable drops fields it does not know when it saves,
    // so an older build must refuse a newer file instead of silently erasing what it cannot read.
    static let currentVersion = 3

    var version = currentVersion
    /// Tags for every crop in the folder; the CLI adds them to each crop's own.
    var tags: [String]?
    var images: [String: ImageTrims] = [:]

    static func load(from folder: URL) throws -> TrimsFile {
        let url = folder.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return TrimsFile() }
        let file = try JSONDecoder().decode(TrimsFile.self, from: Data(contentsOf: url))
        // Saving would drop whatever a newer version added, so refuse rather than lose boxes.
        guard file.version <= currentVersion else { throw TrimsError.newerVersion(file.version) }
        return file
    }

    static func migrateLegacyNames(in folder: URL) throws {
        let files = FileManager.default
        for (old, new) in legacyNames {
            let from = folder.appending(path: old), to = folder.appending(path: new)
            // With both there, the new one is the current work; the old one is left alone for a person to look at.
            guard files.fileExists(atPath: from.path), !files.fileExists(atPath: to.path) else { continue }
            try files.moveItem(at: from, to: to)
        }
    }

    func save(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Atomic, so a crash mid-write leaves the previous file intact instead of a truncated one.
        // Always the current version, whatever was loaded, since the file may now hold fields older builds would drop.
        var file = self
        file.version = Self.currentVersion
        try encoder.encode(file).write(to: folder.appending(path: Self.fileName), options: .atomic)
    }
}

enum TrimsError: LocalizedError {
    case newerVersion(Int)

    var errorDescription: String? {
        switch self {
        case .newerVersion(let v):
            "Plik \(TrimsFile.fileName) ma wersję \(v), nowszą niż obsługuje ta aplikacja. Zaktualizuj aplikację."
        }
    }
}

struct ImageTrims: Codable, Equatable {
    /// Size of the image the boxes were drawn on; a re-scan with another size is flagged in the UI.
    var width: Int
    var height: Int
    /// In drawing order; a box's position, not its id, is its number on screen and in the crop's file name.
    var boxes: [Box] = []
    /// Degrees clockwise that the page is turned about its centre before the boxes apply; nil is level.
    /// Boxes are in pixels of the turned page, which keeps the original's size, with white in the uncovered corners.
    var rotation: Double?
    /// For every crop on this page.
    var tags: [String]?
    var note: String?

    init(size: CGSize) {
        width = Int(size.width)
        height = Int(size.height)
    }

    var size: CGSize { CGSize(width: width, height: height) }

    @discardableResult
    mutating func add(_ rect: CGRect) -> Int {
        // Ids only tell boxes apart while editing (selection, dragging); they are not shown anywhere.
        let id = (boxes.map(\.id).max() ?? 0) + 1
        boxes.append(Box(id: id, rect: rect))
        return id
    }
}

struct Box: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var tags: [String]?
    var note: String?

    init(id: Int, rect: CGRect) {
        self.id = id
        x = 0; y = 0; width = 0; height = 0
        self.rect = rect
    }

    /// Set in place when a box moves, so its tags and note go with it.
    var rect: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = Int(newValue.minX.rounded())
            y = Int(newValue.minY.rounded())
            width = Int(newValue.width.rounded())
            height = Int(newValue.height.rounded())
        }
    }

    var isDescribed: Bool { tags != nil || note != nil }
}
