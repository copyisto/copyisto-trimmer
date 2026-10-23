import SwiftUI

enum InspectorField: Hashable {
    case boxTags, boxNote
    case scanDevice, scanDPI, scanTags, scanNote, trimmerPageNote
    case notebookTags, notebookNote

    var tab: InspectorTab {
        switch self {
        case .boxTags, .boxNote: .crop
        case .notebookTags, .notebookNote: .notebook
        default: .scan
        }
    }
}

enum InspectorTab: Hashable {
    case crop, scan, notebook
}

/// Describes one level at a time: the selected box's crop, the scan, or its notebook.
/// Each tab edits only its own level and shows what it inherits from above, greyed, once.
struct InspectorView: View {
    @Environment(Store.self) private var store
    @FocusState private var focus: InspectorField?

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Picker("Opis", selection: $store.inspectorTab) {
                Text("Wycinek").tag(InspectorTab.crop)
                // In a submission the scan is a file of the notebook's RAW, and its description reaches the server.
                Text(store.submission == nil ? "Skan" : "Skan RAW").tag(InspectorTab.scan)
                Text(store.submission == nil ? "Folder" : "Zeszyt").tag(InspectorTab.notebook)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch store.inspectorTab {
                    case .crop: cropTab
                    case .scan: scanTab
                    case .notebook: notebookTab
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.paper)
        // The Store mirrors the focus, so the menus know when keys like ← and ⌫ belong to the text.
        .onChange(of: focus) { store.editing = focus }
        .onChange(of: store.editing) {
            // A shortcut may switch the tab first; its field exists only from the next turn of the run loop.
            let field = store.editing
            if focus != field { DispatchQueue.main.async { focus = field } }
        }
        .onAppear {
            let field = store.editing
            DispatchQueue.main.async { focus = field }
        }
        .onDisappear { store.editing = nil }
        .onExitCommand { focus = nil }
    }

    // MARK: Crop

    @ViewBuilder
    private var cropTab: some View {
        if let image = store.current {
            let boxes = store.boxes(for: image)
            if let id = store.selectedBox, let index = boxes.firstIndex(where: { $0.id == id }) {
                let box = boxes[index]
                let total = store.cropTags(box: box, on: image).count
                let meta = store.meta(of: image)
                SectionTitle("Wycinek \(String(format: "%03d", index + 1))", detail: "Tylko ten wycinek ze skanu „\(store.fileName(of: image))”.")
                FieldLabel("Tagi")
                TagEditor(
                    tags: box.tags ?? [], inherited: store.inheritedTags(of: image), suggestions: store.tagSuggestions,
                    field: .boxTags, focus: $focus
                ) { store.setBoxTags($0, box: id, on: image) }
                // Half-typed text belongs to the box it was typed for.
                .id(id)
                if total > Tags.maxPerCrop {
                    Warning("Wycinek ma razem z odziedziczonymi \(plural(total, "tag", "tagi", "tagów")) – CLI przyjmie najwyżej \(Tags.maxPerCrop).")
                }
                FieldLabel("Uwaga")
                NoteEditor(
                    note: box.note ?? "",
                    length: store.cropNote(box: box, on: image).utf16.count,
                    help: "Razem z uwagą skanu",
                    field: .boxNote, focus: $focus
                ) { store.setBoxNote($0, box: id, on: image) }
                Inherited(
                    title: "Dziedziczy ze skanu i wyżej",
                    tags: store.inheritedTags(of: image).filter { !(box.tags ?? []).contains($0) },
                    note: Tags.joinedNote(meta.note, store.pageNote(image)),
                    source: store.submission == nil ? nil : Description.label(meta.source))
            } else {
                SectionTitle("Wycinek", detail: nil)
                Hint(boxes.isEmpty ? "Narysuj ramkę na skanie, żeby opisać jej wycinek." : "Zaznacz ramkę na skanie, żeby opisać jej wycinek.")
            }
        } else {
            Hint("Wybierz skan z listy.")
        }
    }

    // MARK: Scan

    @ViewBuilder
    private var scanTab: some View {
        if let image = store.current {
            let level = store.descriptionLevel(of: image)
            let own = store.scanTags(image)
            let above = Tags.merged(store.meta(of: image).tags, store.notebookTags(store.notebookPath(of: image)))
            let total = store.inheritedTags(of: image).count
            let longest = store.boxes(for: image).map { store.cropNote(box: $0, on: image).utf16.count }.max()
            SectionTitle(
                "\(store.submission == nil ? "Skan" : "Skan RAW") „\(store.fileName(of: image))”",
                detail: store.submission == nil ? "Każdy wycinek z tego skanu." : "Ten plik w zgłoszeniu i każdy wycinek z niego.")
            if store.submission != nil { source(image, level: level) }
            FieldLabel("Tagi")
            TagEditor(tags: own, inherited: above, suggestions: store.tagSuggestions, field: .scanTags, focus: $focus) {
                store.setScanTags($0, on: image)
            }
            .id(image)
            if total > Tags.maxPerCrop {
                Warning("Skan ma razem z odziedziczonymi \(plural(total, "tag", "tagi", "tagów")) – CLI przyjmie najwyżej \(Tags.maxPerCrop) na wycinek.")
            }
            FieldLabel("Uwaga")
            NoteEditor(
                note: store.scanNote(image),
                length: longest ?? store.cropNote(box: nil, on: image).utf16.count,
                help: "Razem z najdłuższą uwagą wycinka z tego skanu",
                field: .scanNote, focus: $focus
            ) { store.setScanNote($0, on: image) }
            // Written by the trimmer before the description could hold the scan's note; still sent with each crop.
            if level != nil, !store.pageNote(image).isEmpty {
                FieldLabel("Uwaga z pliku trimmera (dla wycinków)")
                NoteEditor(
                    note: store.pageNote(image),
                    length: longest ?? store.cropNote(box: nil, on: image).utf16.count,
                    help: "Razem z uwagą skanu i najdłuższą uwagą wycinka",
                    field: .trimmerPageNote, focus: $focus
                ) { store.setPageNote($0, on: image) }
            }
            Inherited(
                title: store.submission == nil ? "Dziedziczy z folderu" : "Dziedziczy z zeszytu i zgłoszenia",
                tags: above.filter { !own.contains($0) }, note: "", source: nil)
            if store.submission != nil {
                Footnote(level == nil
                    ? "Zeszyt nie ma jeszcze numeru, więc urządzenie ustawisz po copyisto push. Tagi i uwaga zapisują się w pliku trimmera."
                    : "Zapisuje się w opisie zgłoszenia (.copyisto/description.json); wyśle go copyisto push.")
            }
        } else {
            Hint("Wybierz skan z listy.")
        }
    }

    /// What the scan was taken with; unset fields come from the notebook or the submission, shown as placeholders.
    @ViewBuilder
    private func source(_ image: String, level: [String]?) -> some View {
        let description = store.description
        let number = store.notebook(of: image).flatMap(store.number(of:))
        let above = description.meta(levels: [Description.top] + (number.map { [Description.notebook($0)] } ?? []))
        let own = level.map(description.source(at:)) ?? Description.Source()
        // The device and dpi above apply only while the file keeps their device type.
        let carried = own.deviceType == nil || own.deviceType == above.source.deviceType ? above.source : Description.Source()
        FieldLabel("Urządzenie: \(Description.label(store.meta(of: image).source) ?? "nie podano")")
        Group {
            Picker("Rodzaj", selection: Binding(
                get: { own.deviceType ?? "" },
                set: { value in level.map { store.setDescription(.deviceType, value.isEmpty ? nil : value, at: $0) } }
            )) {
                Text(above.source.deviceType.map { "Jak w zeszycie (\(Description.deviceLabel($0)))" } ?? "Nie podano").tag("")
                ForEach(Description.deviceTypes, id: \.self) { Text(Description.deviceLabel($0).capitalized).tag($0) }
            }
            .labelsHidden()
            HStack(spacing: 6) {
                DraftField(
                    value: own.device ?? "", prompt: carried.device ?? "Model, np. Epson DS-70000",
                    field: .scanDevice, focus: $focus
                ) { text in level.map { store.setDescription(.device, text, at: $0) } }
                DraftField(
                    value: own.dpi.map(String.init) ?? "", prompt: carried.dpi.map { "\($0) dpi" } ?? "DPI",
                    field: .scanDPI, focus: $focus
                ) { text in
                    // Half-typed junk waits in the field instead of erasing the stored dpi.
                    let dpi = Int(text.trimmingCharacters(in: .whitespaces))
                    if let level, dpi != nil || text.isEmpty { store.setDescription(.dpi, dpi, at: level) }
                }
                .frame(width: 72)
            }
        }
        .disabled(level == nil)
    }

    // MARK: Notebook

    @ViewBuilder
    private var notebookTab: some View {
        if let notebook = store.current.flatMap(store.notebook(of:)) ?? store.notebooks.first {
            let level = store.descriptionLevel(of: notebook)
            let own = store.notebookOwnTags(notebook)
            let top = store.description.tags(at: Description.top)
            if let submission = store.submission {
                SectionTitle("Zeszyt \(store.title(of: notebook))", detail: "Każdy skan RAW i wycinek z tego zeszytu.")
                FieldLabel("Tagi")
                TagEditor(tags: own, inherited: top, suggestions: store.tagSuggestions, field: .notebookTags, focus: $focus) {
                    store.setNotebookOwnTags($0, of: notebook)
                }
                .id("notebook:\(notebook.path)")
                FieldLabel("Uwaga do zeszytu (nie trafia do wycinków)")
                NoteEditor(
                    note: level.map(store.description.note(at:)) ?? "",
                    length: level.map { store.description.note(at: $0).utf16.count } ?? 0,
                    help: "Uwaga do zeszytu",
                    field: .notebookNote, focus: $focus
                ) { note in level.map { store.setDescription(.note, note, at: $0) } }
                .disabled(level == nil)
                Inherited(
                    title: "Dziedziczy ze zgłoszenia \(submission.code)",
                    tags: top.filter { !own.contains($0) }, note: "",
                    source: Description.label(store.description.source(at: Description.top)))
                Footnote(level == nil
                    ? "Zeszyt nie ma jeszcze numeru: uwagę ustawisz po copyisto push. Tagi zapisują się w pliku trimmera. Opis całego zgłoszenia zmienisz poleceniem copyisto describe."
                    : "Zapisuje się w opisie zgłoszenia; wyśle go copyisto push. Opis całego zgłoszenia zmienisz poleceniem copyisto describe.")
            } else {
                SectionTitle("Folder „\(notebook.name)”", detail: "Każdy wycinek z tego folderu.")
                FieldLabel("Tagi")
                TagEditor(tags: own, inherited: [], suggestions: store.tagSuggestions, field: .notebookTags, focus: $focus) {
                    store.setNotebookOwnTags($0, of: notebook)
                }
            }
        }
    }
}

private struct FieldLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.text(11, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.top, 2)
    }
}

private struct Hint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.text(12))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What a level gets from the levels above, greyed, so the tab shows the whole picture while editing only its own.
private struct Inherited: View {
    let title: String
    let tags: [String]
    let note: String
    let source: String?

    var body: some View {
        if !tags.isEmpty || !note.isEmpty || source != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.text(10, weight: .medium))
                if let source {
                    Text(source).font(Theme.text(12))
                }
                if !tags.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(tags, id: \.self) { Chip(tag: $0, onRemove: nil) }
                    }
                }
                if !note.isEmpty {
                    Text(note)
                        .font(Theme.text(12))
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            .foregroundStyle(Theme.muted)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sunken, in: .rect(cornerRadius: 6))
            .padding(.top, 6)
        }
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
    /// Tags from the levels above, shown elsewhere; only left out of the suggestions here.
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
            if !tags.isEmpty {
                FlowLayout(spacing: 4) {
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
