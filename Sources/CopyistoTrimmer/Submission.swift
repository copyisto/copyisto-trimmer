import Foundation

/// A submission's folder as `copyisto init` makes it, like a git working copy:
/// `.copyisto/` holds the CLI's state and the shared description, and each notebook is a folder,
/// `01/` once it has a number, or any other name (`nowy/`) until `copyisto push` gives it one.
struct Submission: Equatable {
    static let directory = ".copyisto"
    let code: String
    /// The folder that holds `.copyisto/`.
    let root: URL

    var descriptionURL: URL { root.appending(path: "\(Self.directory)/description.json") }
    var tagsURL: URL { root.appending(path: "\(Self.directory)/tags.json") }

    /// The submission `folder` is, or is a notebook of; nil for any other folder.
    /// Only the folder and its parent are looked at, so a folder of scans somewhere inside one is not mistaken for a notebook.
    static func of(_ folder: URL) -> (submission: Submission, isRoot: Bool)? {
        if let submission = read(folder) { return (submission, true) }
        if let submission = read(folder.deletingLastPathComponent()) { return (submission, false) }
        return nil
    }

    /// Only `code` is read: the rest of state.json is the CLI's own, and it is never written.
    /// A file without a code, or broken, is no submission, so the folder opens as plain scans.
    private static func read(_ root: URL) -> Submission? {
        guard let data = try? Data(contentsOf: root.appending(path: "\(directory)/state.json")),
            let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let code = state["code"] as? String, !code.isEmpty
        else { return nil }
        return Submission(code: code, root: root.standardizedFileURL)
    }

    /// The notebook's number, or nil for a new one that gets its number on push.
    /// A folder named by its number, as in its ID (M4K-V-01): `NOTEBOOK_NUMBER` in shared/description.ts.
    static func number(of folderName: String) -> String? {
        folderName.wholeMatch(of: /\d{2,3}/) == nil ? nil : folderName
    }

    /// „M4K-V-01”, or the folder's name for a notebook without a number yet.
    func title(of folderName: String) -> String {
        Self.number(of: folderName).map { "\(code)-\($0)" } ?? "\(folderName): nowy zeszyt"
    }

    /// Notebook folders in the order of their numbers, new ones last, as the CLI and the website list them.
    static func notebookOrder(_ a: String, _ b: String) -> Bool {
        switch (number(of: a).flatMap { Int($0) }, number(of: b).flatMap { Int($0) }) {
        case let (x?, y?): x != y ? x < y : a < b
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): a.localizedStandardCompare(b) == .orderedAscending
        }
    }
}

/// `.copyisto/description.json`: what the files are, for the whole submission, per notebook and per file
/// (shared/description.ts in copyisto-ingestor). The file is shared and the CLI merges it field by field,
/// so it is kept as plain JSON: keys this build does not know, and other notebooks' parts, are written back untouched.
struct Description {
    static let deviceTypes = ["scanner", "camera", "other"]
    static let maxDevice = 100
    static let maxDPI = 10000

    var json: [String: Any] = [:]

    struct Source: Equatable {
        var deviceType: String?
        var device: String?
        var dpi: Int?

        var isEmpty: Bool { deviceType == nil && device == nil && dpi == nil }
    }

    /// A file's description as it applies, as the CLI and the server work it out; crops inherit it.
    struct Meta: Equatable {
        var source = Source()
        var tags: [String] = []
        var note = ""
    }

    /// One field the trimmer edits, at any level.
    enum Field: Hashable {
        case deviceType, device, dpi, tags, note

        var key: [String] {
            switch self {
            case .deviceType: ["source", "device_type"]
            case .device: ["source", "device"]
            case .dpi: ["source", "dpi"]
            case .tags: ["tags"]
            case .note: ["note"]
            }
        }
    }

    // MARK: Levels

    static let top: [String] = []
    static func notebook(_ number: String) -> [String] { ["notebooks", number] }
    static func file(_ name: String, in number: String) -> [String] { ["notebooks", number, "files", canonical(name)] }

    /// The trimmer's file under its old name is the same file: `canonicalPath` in shared/description.ts.
    static func canonical(_ path: String) -> String {
        path == "copyisto-trims.json" ? TrimsFile.fileName : path
    }

    func value(at path: [String]) -> Any? {
        var node: Any? = json
        for (index, key) in path.enumerated() {
            guard let object = node as? [String: Any] else { return nil }
            // A file listed under the old trimmer name still counts, as the CLI renames it when it reads.
            if index == 3, path[2] == "files", object[key] == nil,
                let alias = object.first(where: { Self.canonical($0.key) == key && $0.key != key })
            {
                node = alias.value
            } else {
                node = object[key]
            }
        }
        return node
    }

    // MARK: Reading, leniently: a value the CLI would refuse is shown as missing rather than failing the page.

    func source(at level: [String]) -> Source {
        Source(
            deviceType: (value(at: level + Field.deviceType.key) as? String).flatMap { Self.deviceTypes.contains($0) ? $0 : nil },
            device: (value(at: level + Field.device.key) as? String).flatMap(Self.device),
            dpi: Self.dpi(value(at: level + Field.dpi.key)))
    }

    func tags(at level: [String]) -> [String] {
        Tags.merged(((value(at: level + Field.tags.key) as? [Any]) ?? []).compactMap { ($0 as? String).flatMap(Tags.validated) })
    }

    func note(at level: [String]) -> String {
        ((value(at: level + Field.note.key) as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The submission's, then the notebook's, then the file's own: tags joined, the note the file's own (a notebook's note
    /// is about the notebook), and the source field by field, except that another device type starts it over,
    /// so a phone photo does not get the scanner's model. `fileMeta` in shared/description.ts.
    func meta(of file: String, in number: String?) -> Meta {
        var meta = meta(levels: [Self.top] + (number.map { [Self.notebook($0), Self.file(file, in: $0)] } ?? []))
        meta.note = number.map { note(at: Self.file(file, in: $0)) } ?? ""
        return meta
    }

    /// What the levels say together, from the top down; the note is left to the caller.
    func meta(levels: [[String]]) -> Meta {
        var meta = Meta()
        for level in levels {
            let own = source(at: level)
            if let type = own.deviceType, type != meta.source.deviceType {
                meta.source = own
            } else {
                meta.source.deviceType = own.deviceType ?? meta.source.deviceType
                meta.source.device = own.device ?? meta.source.device
                meta.source.dpi = own.dpi ?? meta.source.dpi
            }
            meta.tags = Tags.merged(meta.tags, tags(at: level))
        }
        return meta
    }

    /// „skaner Epson DS-70000, 600 dpi”; nil when nothing is known.
    static func label(_ source: Source) -> String? {
        let device = [source.deviceType.map(deviceLabel), source.device].compactMap { $0 }.joined(separator: " ")
        let parts = [device, source.dpi.map { "\($0) dpi" } ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func deviceLabel(_ type: String) -> String {
        switch type {
        case "scanner": "skaner"
        case "camera": "aparat"
        default: "inne"
        }
    }

    // MARK: Normalizing, exactly as the CLI's parser, so a written file never stops `copyisto` from reading it

    static func device(_ text: String) -> String? {
        let device = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return device.isEmpty || device.utf16.count > maxDevice ? nil : device
    }

    static func dpi(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue == number.doubleValue.rounded(), (1...Double(maxDPI)).contains(number.doubleValue)
        else { return nil }
        return number.intValue
    }

    /// The value as stored, or nil to leave the key out: empty text and empty lists are never written.
    static func stored(_ field: Field, _ value: Any?) -> Any? {
        switch field {
        case .deviceType: (value as? String).flatMap { deviceTypes.contains($0) ? $0 : nil }
        case .device: (value as? String).flatMap(device)
        case .dpi: dpi(value)
        case .tags:
            // At most 20 a level, or the CLI refuses the whole file.
            ((value as? [String]) ?? []).compactMap(Tags.validated).reduce(into: [String]()) {
                if !$0.contains($1), $0.count < Tags.maxPerCrop { $0.append($1) }
            }.nilIfEmpty
        case .note:
            Tags.truncated(((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), to: Tags.maxNote).nilIfEmpty
        }
    }

    // MARK: Writing

    /// The description with one value set, or removed when nil; objects left empty on the way are removed too.
    func setting(_ value: Any?, at path: [String]) -> Description {
        Description(json: Self.setting(value, at: path[...], in: json) ?? [:])
    }

    private static func setting(_ value: Any?, at path: ArraySlice<String>, in object: [String: Any]) -> [String: Any]? {
        guard let key = path.first else { return object }
        var object = object
        if path.count == 1 {
            object[key] = value
        } else {
            object[key] = setting(value, at: path.dropFirst(), in: object[key] as? [String: Any] ?? [:])
        }
        return object.isEmpty ? nil : object
    }

    static func read(from url: URL) throws -> Description {
        guard FileManager.default.fileExists(atPath: url.path) else { return Description() }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Description(json: json)
    }

    /// As the CLI writes it (`formatDescription`): sorted keys, two-space indent, a newline at the end; atomically.
    func write(to url: URL) throws {
        try Data((Self.format(json) + "\n").utf8).write(to: url, options: .atomic)
    }

    /// JSON.stringify(value, null, 2) with keys sorted by UTF-16 code units, as JavaScript sorts them.
    static func format(_ value: Any, indent: String = "") -> String {
        let inner = indent + "  "
        switch value {
        case let object as [String: Any]:
            guard !object.isEmpty else { return "{}" }
            let keys = object.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            return "{\n" + keys.map { "\(inner)\(quoted($0)): \(format(object[$0]!, indent: inner))" }.joined(separator: ",\n") + "\n\(indent)}"
        case let array as [Any]:
            guard !array.isEmpty else { return "[]" }
            return "[\n" + array.map { inner + format($0, indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case let text as String:
            return quoted(text)
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        default:
            return "null"
        }
    }

    private static func quoted(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    /// Two values compared as JSON, since `Any` has no ==.
    static func same(_ a: Any?, _ b: Any?) -> Bool {
        format(a ?? NSNull()) == format(b ?? NSNull())
    }
}

extension Collection {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
