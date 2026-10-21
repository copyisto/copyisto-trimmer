import Foundation

/// The rules for tags and notes, exactly as `shared/tags.ts` and `shared/limits.ts` in copyisto-ingestor,
/// which the CLI applies before it sends a crop; checking them here catches what it would refuse.
/// Lengths are UTF-16 code units, as JavaScript counts them.
enum Tags {
    static let maxPerCrop = 20
    static let maxLength = 50
    static let maxNote = 2000
    /// Written by `copyisto raw pull`: the tags in use on the server, most used first. Read only, never written.
    static let usageFile = ".copyisto-tags.json"

    /// Trimmed, inner whitespace collapsed to one space, lowercase: `normalizeTag`.
    static func normalize(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines).replacing(/\s+/, with: " ").lowercased()
    }

    /// The normalized tag, or nil if the server would refuse it: empty, longer than 50 or with a control character.
    static func validated(_ tag: String) -> String? {
        let tag = normalize(tag)
        guard (1...maxLength).contains(tag.utf16.count), !tag.unicodeScalars.contains(where: { $0.value < 0x20 })
        else { return nil }
        return tag
    }

    /// Levels joined without repeats, the first one winning, as the CLI joins them for a crop.
    static func merged(_ levels: [String]?...) -> [String] {
        var seen = Set<String>()
        return levels.flatMap { $0 ?? [] }.filter { seen.insert($0).inserted }
    }

    /// What a tag field shows while typing: already lowercase with single spaces, as it will be saved.
    /// A trailing space stays, so the next word can follow.
    static func typing(_ text: String) -> String {
        var text = text.replacing(/\s+/, with: " ").lowercased()
        while text.first == " " { text.removeFirst() }
        while text.utf16.count > maxLength { text.removeLast() }
        return text
    }

    /// A crop's note as the CLI builds it: the non-empty notes, trimmed, one per line.
    static func joinedNote(_ notes: String?...) -> String {
        notes.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// How long a note may be next to `other`, so the two joined stay within the limit.
    static func noteRoom(besides other: String?) -> Int {
        let other = joinedNote(other).utf16.count
        return maxNote - (other == 0 ? 0 : other + 1)
    }

    /// Cut to `room` UTF-16 units without splitting a character.
    static func truncated(_ text: String, to room: Int) -> String {
        var text = text
        while text.utf16.count > max(room, 0) { text.removeLast() }
        return text
    }

    /// The tags from `.copyisto-tags.json`; a missing or broken file just means no suggestions from it.
    static func usage(in folder: URL) -> [String] {
        struct Usage: Decodable { let tag: String }
        guard let data = try? Data(contentsOf: folder.appending(path: usageFile)),
            let list = try? JSONDecoder().decode([Usage].self, from: data)
        else { return [] }
        return merged(list.compactMap { validated($0.tag) })
    }
}
