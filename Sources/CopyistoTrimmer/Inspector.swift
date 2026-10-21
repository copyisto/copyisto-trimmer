import SwiftUI

enum InspectorField: Hashable {
    case boxTags, boxNote, pageTags, pageNote, folderTags
}

/// Tags and notes for the selected box, its page and the whole folder; `copyisto trims push` sends them with each crop.
struct InspectorView: View {
    @Environment(Store.self) private var store
    @FocusState private var focus: InspectorField?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let image = store.current {
                    boxSection(image)
                    Divider()
                    pageSection(image)
                    Divider()
                }
                folderSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.paper)
        // The Store mirrors the focus, so the menus know when keys like ← and ⌫ belong to the text.
        .onChange(of: focus) { store.editing = focus }
        .onChange(of: store.editing) { if focus != store.editing { focus = store.editing } }
        .onAppear {
            // ⌘T on a hidden inspector opens it first; the field exists only from the next turn of the run loop.
            let field = store.editing
            DispatchQueue.main.async { focus = field }
        }
        .onDisappear { store.editing = nil }
        .onExitCommand { focus = nil }
    }

    @ViewBuilder
    private func boxSection(_ image: String) -> some View {
        let boxes = store.boxes(for: image)
        if let id = store.selectedBox, let index = boxes.firstIndex(where: { $0.id == id }) {
            let box = boxes[index]
            let total = store.cropTags(box: box, on: image).count
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Ramka \(String(format: "%03d", index + 1))", detail: "Tylko ten wycinek.")
                TagEditor(
                    tags: box.tags ?? [],
                    inherited: inherited(Tags.merged(store.folderTags, store.pageTags(image)), own: box.tags),
                    suggestions: store.tagSuggestions,
                    field: .boxTags, focus: $focus
                ) { store.setBoxTags($0, box: id, on: image) }
                // Half-typed text belongs to the box it was typed for.
                .id(id)
                if total > Tags.maxPerCrop {
                    Warning("Wycinek ma \(plural(total, "tag", "tagi", "tagów")) z folderu, strony i ramki – CLI przyjmie najwyżej \(Tags.maxPerCrop).")
                }
                NoteEditor(
                    note: box.note ?? "",
                    length: Tags.joinedNote(store.pageNote(image), box.note).utf16.count,
                    help: "Razem z uwagą strony",
                    field: .boxNote, focus: $focus
                ) { store.setBoxNote($0, box: id, on: image) }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("Ramka", detail: nil)
                Text(boxes.isEmpty ? "Narysuj ramkę na stronie, żeby ją opisać." : "Zaznacz ramkę, żeby ją opisać.")
                    .font(Theme.text(12))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func pageSection(_ image: String) -> some View {
        let total = Tags.merged(store.folderTags, store.pageTags(image)).count
        let longestBox = store.boxes(for: image).map { Tags.joinedNote(store.pageNote(image), $0.note).utf16.count }.max()
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Strona", detail: "Każdy wycinek z „\(image)”.")
            TagEditor(
                tags: store.pageTags(image),
                inherited: inherited(store.folderTags, own: store.pageTags(image)),
                suggestions: store.tagSuggestions,
                field: .pageTags, focus: $focus
            ) { store.setPageTags($0, on: image) }
            .id(image)
            if total > Tags.maxPerCrop {
                Warning("Strona ma z folderem \(plural(total, "tag", "tagi", "tagów")) – CLI przyjmie najwyżej \(Tags.maxPerCrop) na wycinek.")
            }
            NoteEditor(
                note: store.pageNote(image),
                length: longestBox ?? Tags.joinedNote(store.pageNote(image)).utf16.count,
                help: "Razem z najdłuższą uwagą ramki na tej stronie",
                field: .pageNote, focus: $focus
            ) { store.setPageNote($0, on: image) }
        }
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Folder", detail: "Każdy wycinek z tego folderu. Uwagę do zeszytu dodaje się na stronie WWW.")
            TagEditor(
                tags: store.folderTags, inherited: [], suggestions: store.tagSuggestions,
                field: .folderTags, focus: $focus
            ) { store.setFolderTags($0) }
        }
    }

    /// Tags from the levels above, shown for the full picture; one the level sets itself appears once, as its own.
    private func inherited(_ tags: [String], own: [String]?) -> [String] {
        tags.filter { !(own ?? []).contains($0) }
    }
}

private struct SectionTitle: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String?) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.display(16))
                .foregroundStyle(Theme.text)
            if let detail {
                Text(detail)
                    .font(Theme.text(11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Warning: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(Theme.text(11, weight: .medium))
            .foregroundStyle(Theme.warning)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warningSoft, in: .rect(cornerRadius: 6))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Tags as removable chips and a field to add more: Return or a comma adds, Backspace in the empty field removes the last.
/// Every key has a click: the chip's ✕ removes, a suggestion row adds.
struct TagEditor: View {
    let tags: [String]
    let inherited: [String]
    let suggestions: [String]
    let field: InspectorField
    var focus: FocusState<InspectorField?>.Binding
    let onChange: ([String]) -> Void

    @State private var text = ""
    @State private var highlighted: Int?
    @State private var invalid = false

    private var isFocused: Bool { focus.wrappedValue == field }

    /// Up to 8 tags not set yet, starting with the typed text, then containing it.
    private var matches: [String] {
        let query = Tags.normalize(text)
        let open = suggestions.filter { !tags.contains($0) && !inherited.contains($0) }
        guard !query.isEmpty else { return Array(open.prefix(8)) }
        let starts = open.filter { $0.hasPrefix(query) }
        let contains = open.filter { !$0.hasPrefix(query) && $0.contains(query) }
        return Array((starts + contains).prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tags.isEmpty || !inherited.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(inherited, id: \.self) { tag in
                        Chip(tag: tag, onRemove: nil)
                    }
                    ForEach(tags, id: \.self) { tag in
                        Chip(tag: tag) { onChange(tags.filter { $0 != tag }) }
                    }
                }
            }
            TextField("Dodaj tag…", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Theme.text(12))
                .focused(focus, equals: field)
                .onChange(of: text) { typed() }
                .onSubmit { submit() }
                .onKeyPress(.delete) {
                    guard text.isEmpty, let last = tags.last else { return .ignored }
                    onChange(tags.filter { $0 != last })
                    return .handled
                }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
            if invalid {
                Text("Tag ma od 1 do \(Tags.maxLength) znaków, bez znaków sterujących.")
                    .font(Theme.text(11))
                    .foregroundStyle(Theme.warning)
            }
            if isFocused, !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element) { index, tag in
                        Button { add([tag]) } label: {
                            Label(tag, systemImage: "plus")
                                .font(Theme.text(12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(index == highlighted ? Theme.accent.opacity(0.14) : .clear, in: .rect(cornerRadius: 4))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.text)
                    }
                }
                .padding(4)
                .background(Theme.surface, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            }
        }
    }

    /// Shows the tag as it will be saved; a comma ends a tag, so pasted "a, b, c" becomes three.
    private func typed() {
        invalid = false
        highlighted = nil
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let rest = Tags.typing(parts.removeLast())
        if !parts.isEmpty { add(parts, keep: rest) }
        if text != rest { text = rest }
    }

    private func submit() {
        if let highlighted, matches.indices.contains(highlighted) {
            add([matches[highlighted]])
        } else if !Tags.normalize(text).isEmpty {
            add([text])
        }
    }

    /// Adds valid tags; an invalid one stays in the field with a hint instead of vanishing.
    private func add(_ new: [String], keep rest: String = "") {
        let valid = new.compactMap(Tags.validated)
        invalid = valid.count < new.filter { !Tags.normalize($0).isEmpty }.count
        if !valid.isEmpty { onChange(Tags.merged(tags, valid)) }
        text = invalid ? Tags.typing(new.last ?? "") : rest
        highlighted = nil
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .ignored }
        highlighted = highlighted.map { min(max($0 + step, 0), matches.count - 1) } ?? (step > 0 ? 0 : matches.count - 1)
        return .handled
    }
}

private struct Chip: View {
    let tag: String
    /// nil for a tag inherited from the page or folder, which is removed there.
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(Theme.text(12))
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Usuń tag „\(tag)”")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, onRemove == nil ? 8 : 6)
        .padding(.vertical, 3)
        .foregroundStyle(onRemove == nil ? Theme.muted : Theme.accent)
        .background(onRemove == nil ? Theme.sunken : Theme.accent.opacity(0.12), in: .capsule)
        .help(onRemove == nil ? "Odziedziczony ze strony albo folderu – usuń go tam" : tag)
    }
}

/// Free text over several lines, with the count the CLI checks against its limit.
private struct NoteEditor: View {
    let note: String
    let length: Int
    let help: String
    let field: InspectorField
    var focus: FocusState<InspectorField?>.Binding
    let onChange: (String) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextEditor(text: Binding(get: { note }, set: onChange))
                .font(Theme.text(12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 64, maxHeight: 160)
                .background(Theme.surface, in: .rect(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if note.isEmpty {
                        Text("Uwaga…")
                            .font(Theme.text(12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(focus.wrappedValue == field ? Theme.accent : Theme.border))
                .focused(focus, equals: field)
            Text("\(length) / \(Tags.maxNote)")
                .font(Theme.text(10).monospacedDigit())
                .foregroundStyle(length >= Tags.maxNote ? Theme.warning : Theme.muted)
                .help(help)
        }
    }
}

/// Lays chips out in rows, wrapping to the width it is given.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, origin) in zip(subviews, arrange(subviews, width: bounds.width).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, widest, y + rowHeight)
    }
}
