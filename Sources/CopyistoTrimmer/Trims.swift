import CoreGraphics
import Foundation

/// The boxes for one folder of scans, stored next to them as `copyisto-trims.json`.
/// Coordinates are in pixels of the original image, like labelme, so they never depend on the window size.
struct TrimsFile: Codable, Equatable {
    static let fileName = "copyisto-trims.json"
    // 2 added `rotation`; version 1 apps refuse it instead of dropping the rotation on their next save.
    static let currentVersion = 2

    var version = currentVersion
    var images: [String: ImageTrims] = [:]

    static func load(from folder: URL) throws -> TrimsFile {
        let url = folder.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return TrimsFile() }
        let file = try JSONDecoder().decode(TrimsFile.self, from: Data(contentsOf: url))
        // Saving would drop whatever a newer version added, so refuse rather than lose boxes.
        guard file.version <= currentVersion else { throw TrimsError.newerVersion(file.version) }
        return file
    }

    func save(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Atomic, so a crash mid-write leaves the previous file intact instead of a truncated one.
        try encoder.encode(self).write(to: folder.appending(path: Self.fileName), options: .atomic)
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

    init(id: Int, rect: CGRect) {
        self.id = id
        x = Int(rect.minX.rounded())
        y = Int(rect.minY.rounded())
        width = Int(rect.width.rounded())
        height = Int(rect.height.rounded())
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
