import SwiftUI

enum InspectorField: Hashable {
    case boxTags, boxNote, pageTags, pageNote, folderTags
    case fileDevice, fileDPI, fileTags, fileNote, notebookTags, notebookNote
}

/// Tags and notes for the selected box, its page and its notebook, which `copyisto push` sends with each crop;
/// in a submission also the shared description of the file, the notebook and the whole submission.
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
                    if store.submission != nil {
                        Divider()
                        fileSection(image)
                    }
                    Divider()
                }
                if let notebook = store.current.flatMap(store.notebook(of:)) ?? store.notebooks.first {
                    notebookSection(notebook)
                }
                if let submission = store.submission {
                    Divider()
                    submissionSection(submission)
                }
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
                    inherited: inherited(store.inheritedTags(of: image), own: box.tags),
                    suggestions: store.tagSuggestions,
                    field: .boxTags, focus: $focus
                ) { store.setBoxTags($0, box: id, on: image) }
                // Half-typed text belongs to the box it was typed for.
                .id(id)
                if total > Tags.maxPerCrop {
                    Warning("Wycinek ma \(plural(total, "tag", "tagi", "tagów")) razem z odziedziczonymi – CLI przyjmie najwyżej \(Tags.maxPerCrop).")
                }
                NoteEditor(
                    note: box.note ?? "",
                    length: store.cropNote(box: box, on: image).utf16.count,
                    help: store.submission == nil ? "Razem z uwagą strony" : "Razem z uwagą pliku i strony",
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
        let above = Tags.merged(store.meta(of: image).tags, store.notebookTags(store.notebookPath(of: image)))
        let total = store.inheritedTags(of: image).count
        let longest = store.boxes(for: image).map { store.cropNote(box: $0, on: image).utf16.count }.max()
        let fileNote = store.meta(of: image).note
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Strona", detail: "Każdy wycinek z „\(store.fileName(of: image))”.")
            TagEditor(
                tags: store.pageTags(image),
                inherited: inherited(above, own: store.pageTags(image)),
                suggestions: store.tagSuggestions,
                field: .pageTags, focus: $focus
            ) { store.setPageTags($0, on: image) }
            .id(image)
            if total > Tags.maxPerCrop {
                Warning("Strona ma razem z odziedziczonymi \(plural(total, "tag", "tagi", "tagów")) – CLI przyjmie najwyżej \(Tags.maxPerCrop) na wycinek.")
            }
            if !fileNote.isEmpty {
                InheritedNote(title: "Uwaga pliku z opisu", text: fileNote)
            }
            NoteEditor(
                note: store.pageNote(image),
                length: longest ?? store.cropNote(box: nil, on: image).utf16.count,
                help: "Razem z najdłuższą uwagą ramki na tej stronie",
                field: .pageNote, focus: $focus
            ) { store.setPageNote($0, on: image) }
        }
    }

    /// The scan's own part of the shared description: what it was taken with, its tags and note, for it and its crops.
    private func fileSection(_ image: String) -> some View {
        let level = store.descriptionLevel(of: image)
        let meta = store.meta(of: image)
        let description = store.description
        let number = store.notebook(of: image).flatMap(store.number(of:))
        let above = description.meta(levels: [Description.top] + (number.map { [Description.notebook($0)] } ?? []))
        let own = level.map(description.source(at:)) ?? Description.Source()
        // The device and dpi above apply only while the file keeps their device type.
        let carried = own.deviceType == nil || own.deviceType == above.source.deviceType ? above.source : Description.Source()
        let longest = store.boxes(for: image).map { store.cropNote(box: $0, on: image).utf16.count }.max()
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Plik w opisie zgłoszenia", detail: "Skan i każdy wycinek z niego.")
            Text(Description.label(meta.source) ?? "Źródło nieznane")
                .font(Theme.text(12, weight: .medium))
                .foregroundStyle(Theme.text)
            Group {
                Picker("Urządzenie", selection: Binding(
                    get: { own.deviceType ?? "" },
                    set: { value in level.map { store.setDescription(.deviceType, value.isEmpty ? nil : value, at: $0) } }
                )) {
                    Text(above.source.deviceType.map { "Jak w zeszycie (\(Description.deviceLabel($0)))" } ?? "Nie podano").tag("")
                    ForEach(Description.deviceTypes, id: \.self) { Text(Description.deviceLabel($0).capitalized).tag($0) }
                }
                HStack(spacing: 6) {
                    DraftField(
                        value: own.device ?? "", prompt: carried.device ?? "Model, np. Epson DS-70000",
                        field: .fileDevice, focus: $focus
                    ) { text in level.map { store.setDescription(.device, text, at: $0) } }
                    DraftField(
                        value: own.dpi.map(String.init) ?? "", prompt: carried.dpi.map { "\($0)" } ?? "DPI",
                        field: .fileDPI, focus: $focus
                    ) { text in
                        // Half-typed junk waits in the field instead of erasing the stored dpi.
                        let dpi = Int(text.trimmingCharacters(in: .whitespaces))
                        if let level, dpi != nil || text.isEmpty { store.setDescription(.dpi, dpi, at: level) }
                    }
                    .frame(width: 64)
                }
                TagEditor(
                    tags: level.map(description.tags(at:)) ?? [],
                    inherited: inherited(above.tags, own: level.map(description.tags(at:))),
                    suggestions: store.tagSuggestions,
                    field: .fileTags, focus: $focus
                ) { tags in level.map { store.setDescription(.tags, tags, at: $0) } }
                .id("file:\(image)")
                NoteEditor(
                    note: meta.note,
                    length: longest ?? store.cropNote(box: nil, on: image).utf16.count,
                    help: "Razem z uwagami strony i najdłuższą uwagą ramki",
                    field: .fileNote, focus: $focus
                ) { store.setFileNote($0, on: image) }
            }
            .disabled(level == nil)
            Footnote(level == nil ? "Opis plików nowego zeszytu – po copyisto push, kiedy zeszyt dostanie numer." : "Zapisuje się w opisie zgłoszenia; wyśle go copyisto push.")
        }
    }

    private func notebookSection(_ notebook: Notebook) -> some View {
        let trimmerTags = TagEditor(
            tags: store.notebookTags(notebook.path), inherited: [], suggestions: store.tagSuggestions,
            field: .folderTags, focus: $focus
        ) { store.setNotebookTags($0, of: notebook.path) }
        return VStack(alignment: .leading, spacing: 10) {
            if store.submission != nil {
                let level = store.descriptionLevel(of: notebook)
                let description = store.description
                SectionTitle("Zeszyt \(store.title(of: notebook))", detail: "Jego pliki i ich wycinki.")
                Group {
                    TagEditor(
                        tags: level.map(description.tags(at:)) ?? [],
                        inherited: inherited(description.tags(at: Description.top), own: level.map(description.tags(at:))),
                        suggestions: store.tagSuggestions,
                        field: .notebookTags, focus: $focus
                    ) { tags in level.map { store.setDescription(.tags, tags, at: $0) } }
                    .id("notebook:\(notebook.path)")
                    NoteEditor(
                        note: level.map(description.note(at:)) ?? "",
                        length: level.map { description.note(at: $0).utf16.count } ?? 0,
                        help: "Uwaga do zeszytu; nie trafia do wycinków",
                        field: .notebookNote, focus: $focus
                    ) { note in level.map { store.setDescription(.note, note, at: $0) } }
                }
                .disabled(level == nil)
                Footnote(level == nil ? "Opis nowego zeszytu – po copyisto push, kiedy dostanie numer." : "Uwaga dotyczy zeszytu, nie wycinków. Wyśle ją copyisto push.")
                Text("Tagi z trimmera dla każdego wycinka z zeszytu")
                    .font(Theme.text(12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 4)
                trimmerTags
            } else {
                SectionTitle("Folder", detail: "Każdy wycinek z tego folderu.")
                trimmerTags
            }
        }
    }

    /// Set for the whole submission with `copyisto describe`; shown for the full picture, not edited here.
    private func submissionSection(_ submission: Submission) -> some View {
        let description = store.description
        let tags = description.tags(at: Description.top)
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Zgłoszenie \(submission.code)", detail: "Każdy plik zgłoszenia. Zmienisz to poleceniem copyisto describe.")
            Text(Description.label(description.source(at: Description.top)) ?? "Źródło nie podane")
                .font(Theme.text(12))
                .foregroundStyle(Theme.muted)
            if !tags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(tags, id: \.self) { Chip(tag: $0, onRemove: nil) }
                }
            }
        }
    }

    /// Tags from the levels above, shown for the full picture; one the level sets itself appears once, as its own.
    private func inherited(_ tags: [String], own: [String]?) -> [String] {
        tags.filter { !(own ?? []).contains($0) }
    }
}

private struct Footnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.text(11))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A note from a level above, greyed like inherited tags; it is edited where it belongs.
private struct InheritedNote: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.text(10, weight: .medium))
            Text(text)
                .font(Theme.text(12))
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .foregroundStyle(Theme.muted)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sunken, in: .rect(cornerRadius: 6))
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
    /// nil for a tag inherited from a level above, which is removed there.
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
        .help(onRemove == nil ? "Odziedziczony z wyższego poziomu – usuń go tam" : tag)
    }
}

/// Free text over several lines, with the count the CLI checks against its limit.
/// It types into a draft, since the stored note may be trimmed or cut to the limit; the draft follows the stored note
/// whenever they really differ, e.g. after undo, a cut, or a change in the file.
private struct NoteEditor: View {
    let note: String
    let length: Int
    let help: String
    let field: InspectorField
    var focus: FocusState<InspectorField?>.Binding
    let onChange: (String) -> Void

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextEditor(text: $draft)
                .font(Theme.text(12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 64, maxHeight: 160)
                .background(Theme.surface, in: .rect(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
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
                .onAppear { draft = note }
                .onChange(of: note) { if !matches(draft, note) { draft = note } }
                .onChange(of: draft) { if !matches(draft, note) { onChange(draft) } }
            Text("\(length) / \(Tags.maxNote)")
                .font(Theme.text(10).monospacedDigit())
                .foregroundStyle(length >= Tags.maxNote ? Theme.warning : Theme.muted)
                .help(help)
        }
    }
}

/// A one-line field that types into a draft, like `NoteEditor`, so a trailing space survives until the next word.
private struct DraftField: View {
    let value: String
    let prompt: String
    let field: InspectorField
    var focus: FocusState<InspectorField?>.Binding
    let onChange: (String) -> Void

    @State private var draft = ""

    var body: some View {
        TextField(prompt, text: $draft, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .font(Theme.text(12))
            .focused(focus, equals: field)
            .onAppear { draft = value }
            .onChange(of: value) { if !matches(draft, value) { draft = value } }
            .onChange(of: draft) { if !matches(draft, value) { onChange(draft) } }
    }
}

/// True when `stored` is what `draft` saves as: the same text, or the same trimmed.
private func matches(_ draft: String, _ stored: String) -> Bool {
    draft == stored || draft.trimmingCharacters(in: .whitespacesAndNewlines) == stored
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
