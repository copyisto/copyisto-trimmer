import CoreGraphics
import Foundation
import os

/// Where a folder of scans keeps the trimmer's work: one hidden folder, `.trims/`, with the boxes in `trims.json`
/// and the exported crops in `crops/`. Hidden, so Finder lists only the scans and ⌘A never takes the boxes or crops along.
/// `copyisto` looks in the same places (cli/raw.ts).
enum TrimsLocation {
    static let folder = ".trims"
    static let file = "trims.json"
    static let crops = "crops"
    /// The layouts before, newest first: the file and the crops' folder next to the scans.
    static let legacyNames = [("trims.copyisto.json", "trims.copyisto"), ("copyisto-trims.json", "copyisto-trims")]
    /// The file's name in a notebook's RAW on the server, and so in the description, wherever the folder keeps it.
    static let rawName = "trims.copyisto.json"

    private static let log = Logger(subsystem: "com.copyisto.trimmer", category: "trims")

    static func file(in folder: URL) -> URL { folder.appending(path: "\(Self.folder)/\(file)") }
    static func crops(in folder: URL) -> URL { folder.appending(path: "\(Self.folder)/\(crops)", directoryHint: .isDirectory) }

    /// The file to read: `.trims/trims.json`, else the first old one there is.
    static func current(in folder: URL) -> URL? {
        ([file(in: folder)] + legacyNames.map { folder.appending(path: $0.0) })
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Moves an old layout into `.trims/` when a folder opens, contents untouched, so a folder cut with an older build
    /// carries on where it left off. A folder that has `.trims/trims.json` already is left alone, old files included.
    /// A move that fails is only logged: the old file is then read, so nothing is lost.
    static func migrate(in folder: URL) {
        let files = FileManager.default
        guard !files.fileExists(atPath: file(in: folder).path) else { return }
        let oldFile = legacyNames.map { folder.appending(path: $0.0) }.first { files.fileExists(atPath: $0.path) }
        let oldCrops = legacyNames.map { folder.appending(path: $0.1) }.first { files.fileExists(atPath: $0.path) }
        guard oldFile != nil || oldCrops != nil else { return }
        do {
            try files.createDirectory(at: folder.appending(path: Self.folder), withIntermediateDirectories: true)
            if let oldFile { try files.moveItem(at: oldFile, to: file(in: folder)) }
            if let oldCrops, !files.fileExists(atPath: crops(in: folder).path) { try files.moveItem(at: oldCrops, to: crops(in: folder)) }
        } catch {
            log.error("Could not move the old trimmer files in \(folder.path, privacy: .public) into .trims: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Old files next to a `.trims/` that has the file, which neither the app nor the CLI uses any more.
    static func leftovers(in folder: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: file(in: folder).path) else { return [] }
        return legacyNames.flatMap { [$0.0, $0.1] }.filter { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
    }
}

/// The boxes for one folder of scans, in `.trims/trims.json` (`TrimsLocation`).
/// Coordinates are in pixels of the original image, like labelme, so they never depend on the window size.
struct TrimsFile: Codable, Equatable {
    // 2 added `rotation`, 3 added `tags` and `note`.
    // Every new field needs a new version: Codable drops fields it does not know when it saves,
    // so an older build must refuse a newer file instead of silently erasing what it cannot read.
    static let currentVersion = 3

    var version = currentVersion
    /// Tags for every crop in the folder; the CLI adds them to each crop's own.
    var tags: [String]?
    var images: [String: ImageTrims] = [:]

    static func load(from folder: URL) throws -> TrimsFile {
        guard let url = TrimsLocation.current(in: folder) else { return TrimsFile() }
        let file = try JSONDecoder().decode(TrimsFile.self, from: Data(contentsOf: url))
        // Saving would drop whatever a newer version added, so refuse rather than lose boxes.
        guard file.version <= currentVersion else { throw TrimsError.newerVersion(file.version) }
        return file
    }

    func save(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Atomic, so a crash mid-write leaves the previous file intact instead of a truncated one.
        // Always the current version, whatever was loaded, since the file may now hold fields older builds would drop.
        var file = self
        file.version = Self.currentVersion
        // Only `.trims` itself is made: a notebook folder that is gone, e.g. renamed by `copyisto push`, must not come back.
        let hidden = folder.appending(path: TrimsLocation.folder)
        if !FileManager.default.fileExists(atPath: hidden.path) {
            try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
        }
        try encoder.encode(file).write(to: TrimsLocation.file(in: folder), options: .atomic)
    }
}

enum TrimsError: LocalizedError {
    case newerVersion(Int)

    var errorDescription: String? {
        switch self {
        case .newerVersion(let v):
            "Plik z ramkami (\(TrimsLocation.folder)/\(TrimsLocation.file)) ma wersję \(v), nowszą niż obsługuje ta aplikacja. Zaktualizuj aplikację."
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
