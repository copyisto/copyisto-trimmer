import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store

    var body: some View {
        alerts(main)
    }

    private var main: some View {
        @Bindable var store = store
        return Group {
            if store.folder != nil {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
                } detail: {
                    detail
                        .inspector(isPresented: $store.showsInspector) {
                            InspectorView()
                                .inspectorColumnWidth(min: 240, ideal: 280, max: 420)
                        }
                }
                .navigationTitle(store.title)
                .navigationSubtitle(subtitle)
                .toolbar { toolbar }
            } else {
                EmptyState()
            }
        }
        .tint(Theme.accent)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            store.open(url)
            return true
        }
        .sheet(isPresented: $store.showsLabs) { LabsSheet() }
        .fileImporter(isPresented: $store.isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.open(url) }
        }
        .task(id: store.current) { store.prefetch() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.reload()
        }
    }

    private func alerts(_ content: some View) -> some View {
        content
            .alert(
                "Coś poszło nie tak",
                isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } }),
                presenting: store.error
            ) { _ in
                Button("OK") {}
            } message: { Text($0) }
            .alert(
                store.exportSummary?.notebooks.isEmpty == true ? "Wycinki są aktualne" : "Eksport gotowy",
                isPresented: Binding(get: { store.exportSummary != nil }, set: { if !$0 { store.exportSummary = nil } }),
                presenting: store.exportSummary
            ) { summary in
                if !summary.folders.isEmpty { Button("Pokaż w Finderze") { store.revealExport() } }
                Button("OK", role: .cancel) {}
            } message: { summary in
                Text(exportMessage(summary))
            }
            .alert(
                "Opis zmienił się w pliku",
                isPresented: Binding(get: { store.descriptionConflict != nil }, set: { if !$0 { store.descriptionConflict = nil } }),
                presenting: store.descriptionConflict
            ) { conflict in
                Button("Zostaw moje") { store.keepMine(conflict) }
                Button("Weź z pliku", role: .cancel) {}
            } message: { conflict in
                Text("Pole „\(conflict.label)” zmieniło się w .copyisto/description.json, odkąd aplikacja je wczytała (np. po copyisto pull). Które zostawić?")
            }
    }

    private var subtitle: String {
        let pages = plural(store.images.count, "zdjęcie", "zdjęcia", "zdjęć")
        let crops = plural(store.totalBoxes, "wycinek", "wycinki", "wycinków")
        return "\(pages) · \(crops)"
    }

    private func exportMessage(_ summary: ExportSummary) -> String {
        guard !summary.notebooks.isEmpty else { return "Od ostatniego eksportu żadna ramka się nie zmieniła." }
        let what = "Wyeksportowano \(plural(summary.crops, "wycinek", "wycinki", "wycinków")) z \(plural(summary.images, "zdjęcia", "zdjęć", "zdjęć"))"
        guard store.submission != nil else { return "\(what) do folderu \(Exporter.folderName)." }
        return "\(what) do \(Exporter.folderName) w zeszytach: \(summary.notebooks.joined(separator: ", "))."
    }

    private var sidebar: some View {
        @Bindable var store = store
        return List(selection: $store.current) {
            if !store.strayFiles.isEmpty {
                Label {
                    Text("Pliki poza zeszytami: \(store.strayFiles.joined(separator: ", ")) – przenieś je do folderu zeszytu.")
                        // A sidebar row is one line unless told otherwise, which cut off the names.
                        .lineLimit(4)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                }
                .font(Theme.text(11))
                .foregroundStyle(Theme.muted)
                .selectionDisabled()
            }
            // One notebook needs no headers; several get one each, foldable, in the order of their numbers.
            if store.notebooks.count > 1 {
                ForEach(store.notebooks) { notebook in
                    Section(isExpanded: Binding(
                        get: { !store.collapsed.contains(notebook.path) },
                        set: { if $0 { store.collapsed.remove(notebook.path) } else { store.collapsed.insert(notebook.path) } }
                    )) {
                        ForEach(notebook.images, id: \.self) { image in
                            SidebarRow(image: image).tag(image)
                        }
                        if notebook.images.isEmpty {
                            Text("Brak skanów")
                                .font(Theme.text(12))
                                .foregroundStyle(Theme.muted)
                                .selectionDisabled()
                        }
                    } header: {
                        NotebookHeader(notebook: notebook)
                    }
                }
            } else {
                ForEach(store.images, id: \.self) { image in
                    SidebarRow(image: image).tag(image)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let image = store.current, let url = store.url(for: image) {
            CanvasView(image: image, url: url)
        } else {
            Text(store.images.isEmpty ? emptyMessage : "Wybierz zdjęcie z listy.")
                .font(Theme.text(14))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.sunken)
        }
    }

    private var emptyMessage: String {
        guard store.isSubmissionRoot else { return "W tym folderze nie ma zdjęć PNG ani JPG." }
        return store.notebooks.isEmpty
            ? "Zgłoszenie nie ma jeszcze zeszytów: pobierz je (copyisto pull) albo załóż folder nowego zeszytu, np. nowy/."
            : "W zeszytach nie ma jeszcze zdjęć PNG ani JPG (copyisto pull)."
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var store = store
        // Every menu command and shortcut also has a button here, so nothing is reachable only from the keyboard.
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button("Poprzednie zdjęcie", systemImage: "chevron.left") { store.step(-1) }
                    .disabled(!store.canStep(-1))
                    .help("Poprzednie zdjęcie (←)")
                Button("Następne zdjęcie", systemImage: "chevron.right") { store.step(1) }
                    .disabled(!store.canStep(1))
                    .help("Następne zdjęcie (→)")
            }
        }
        ToolbarItem {
            Button("Otwórz folder…", systemImage: "folder") { store.isPickingFolder = true }
                .help("Otwórz inny folder zgłoszenia albo skanów (⌘O)")
        }
        ToolbarItem {
            ControlGroup {
                Button("Cofnij", systemImage: "arrow.uturn.backward") { store.undo() }
                    .disabled(!store.canUndo)
                    .help("Cofnij (⌘Z)")
                Button("Ponów", systemImage: "arrow.uturn.forward") { store.redo() }
                    .disabled(!store.canRedo)
                    .help("Ponów (⇧⌘Z)")
            }
        }
        ToolbarItem {
            Button("Usuń zaznaczony box", systemImage: "trash") { store.deleteSelected() }
                .disabled(store.selectedBox == nil)
                .help("Usuń zaznaczony box (⌫)")
        }
        ToolbarItem {
            ControlGroup {
                Button("Pomniejsz", systemImage: "minus.magnifyingglass") { store.zoomOut() }
                    .disabled(store.zoom <= 1)
                    .help("Pomniejsz (⌘-)")
                Button { store.zoomToFit() } label: {
                    // Relative to fitting the page in the window, which is 100%.
                    Text("\(Int((store.zoom * 100).rounded()))%")
                        .font(Theme.text(12).monospacedDigit())
                        .frame(minWidth: 40)
                }
                .disabled(store.zoom == 1)
                .help("Dopasuj do okna (⌘0)")
                Button("Powiększ", systemImage: "plus.magnifyingglass") { store.zoomIn() }
                    .disabled(store.zoom >= Store.zoomSteps.last!)
                    .help("Powiększ (⌘+)")
            }
        }
        ToolbarItem {
            let angle = store.current.map(store.rotation(of:)) ?? 0
            ControlGroup {
                Button("Obróć w lewo", systemImage: "rotate.left") { store.rotateCurrent(by: -Store.rotationStep) }
                    .help("Obróć zdjęcie o 0,1° w lewo ([)")
                Button { store.resetRotation() } label: {
                    Text(angleLabel(angle))
                        .font(Theme.text(12).monospacedDigit())
                        .frame(minWidth: 44)
                }
                .disabled(angle == 0)
                .help("Bez obrotu")
                Button("Obróć w prawo", systemImage: "rotate.right") { store.rotateCurrent(by: Store.rotationStep) }
                    .help("Obróć zdjęcie o 0,1° w prawo (])")
                Button("Wyprostuj automatycznie", systemImage: "level") { Task { await store.straightenCurrent() } }
                    .disabled(store.isStraightening)
                    .help("Wyprostuj automatycznie według pięciolinii (⌘L)")
            }
            .disabled(store.current == nil)
        }
        ToolbarItem {
            Picker("Format eksportu", selection: $store.format) {
                ForEach(ExportFormat.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Format plików z wycinkami; zbiór danych potrzebuje PNG, JPG jest stratny")
        }
        ToolbarItem {
            if let progress = store.exportProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(progress.done) / \(progress.total)")
                        .font(Theme.text(12).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 8)
            } else {
                Button {
                    Task { await store.export() }
                } label: {
                    Label("Eksportuj", systemImage: "scissors")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.totalBoxes == 0)
                .help("Zapisz boxy jako osobne pliki w \(Exporter.folderName) każdego zeszytu, w którym się zmieniły (⌘E)")
            }
        }
        ToolbarItem {
            Button("Copyisto Labs", systemImage: "arrow.up.arrow.down.circle") { store.showsLabs = true }
                .help("Pobierz zeszyt albo wyślij wycinki na serwer (⇧⌘E)")
        }
        ToolbarItem {
            Button("Tagi i uwagi", systemImage: "sidebar.trailing") { store.showsInspector.toggle() }
                .help(store.showsInspector ? "Ukryj tagi i uwagi (⌥⌘I)" : "Pokaż tagi i uwagi (⌥⌘I)")
        }
    }
}

/// 0,46° with a Polish decimal comma; up to two decimals, as rotations are stored.
func angleLabel(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "pl_PL"))) + "°"
}

/// Its own view, so it observes the box count itself: an inline List row is not redrawn
/// when only the boxes change, which left new pages unmarked until something else refreshed the list.
private struct SidebarRow: View {
    @Environment(Store.self) private var store
    let image: String

    var body: some View {
        let count = store.boxes(for: image).count
        let isSelected = store.current == image
        HStack(spacing: 8) {
            // Done pages get a filled mark, so what is left to crop stands out at a glance.
            Image(systemName: count > 0 ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : count > 0 ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
            Text(store.fileName(of: image))
                .font(Theme.text(13))
                .lineLimit(1)
                .truncationMode(.middle)
                // Semantic styles, so the text inverts on the selected row; pages still to do are dimmed.
                .foregroundStyle(count > 0 ? .primary : .secondary)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(Theme.text(11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
    }
}

/// A notebook's title in the list, with its note from the description and its state.
private struct NotebookHeader: View {
    @Environment(Store.self) private var store
    let notebook: Notebook

    var body: some View {
        let note = store.descriptionLevel(of: notebook).map(store.description.note(at:)) ?? ""
        VStack(alignment: .leading, spacing: 2) {
            Text(store.title(of: notebook))
                .font(Theme.text(12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if store.number(of: notebook) == nil {
                Text("numer nada copyisto push")
                    .font(Theme.text(11))
                    .foregroundStyle(Theme.muted)
            }
            if !note.isEmpty {
                Text(note)
                    .font(Theme.text(11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .help(note)
            }
        }
        .contextMenu {
            Button("Opisz zeszyt") {
                if let first = notebook.images.first, store.notebook(of: store.current ?? "") != notebook { store.current = first }
                store.describe(.notebookNote)
            }
            .disabled(notebook.images.isEmpty || store.number(of: notebook) == nil)
        }
    }
}

private struct EmptyState: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 18) {
            Text("Copyisto Trimmer")
                .font(Theme.display(34))
                .foregroundStyle(Theme.text)
            Text("Zaznacz na skanach fragmenty z nutami i wyeksportuj je jako osobne pliki.")
                .font(Theme.text(14))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            Button("Otwórz folder zgłoszenia albo skanów…") { store.isPickingFolder = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
            Text("albo przeciągnij folder tutaj")
                .font(Theme.text(12))
                .foregroundStyle(Theme.muted)
            Button("Pobierz zgłoszenie z Copyisto Labs…") { store.showsLabs = true }
                .controlSize(.large)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
    }
}
