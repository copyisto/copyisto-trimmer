import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        Group {
            if let folder = store.folder {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
                } detail: {
                    detail
                }
                .navigationTitle(folder.lastPathComponent)
                .navigationSubtitle(
                    "\(plural(store.images.count, "zdjęcie", "zdjęcia", "zdjęć")) · "
                        + plural(store.totalBoxes, "wycinek", "wycinki", "wycinków"))
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
        .fileImporter(isPresented: $store.isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.open(url) }
        }
        .task(id: store.current) { store.prefetch() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshImages()
        }
        .alert(
            "Coś poszło nie tak",
            isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } }),
            presenting: store.error
        ) { _ in
            Button("OK") {}
        } message: { Text($0) }
        .alert(
            "Eksport gotowy",
            isPresented: Binding(get: { store.exportSummary != nil }, set: { if !$0 { store.exportSummary = nil } }),
            presenting: store.exportSummary
        ) { _ in
            Button("Pokaż w Finderze") { store.revealExport() }
            Button("OK", role: .cancel) {}
        } message: { summary in
            Text(
                "Wyeksportowano \(plural(summary.crops, "wycinek", "wycinki", "wycinków")) "
                    + "z \(plural(summary.images, "zdjęcia", "zdjęć", "zdjęć")) do folderu \(Exporter.folderName).")
        }
    }

    private var sidebar: some View {
        @Bindable var store = store
        return List(selection: $store.current) {
            ForEach(store.images, id: \.self) { image in
                SidebarRow(image: image).tag(image)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let image = store.current, let url = store.url(for: image) {
            CanvasView(image: image, url: url)
        } else {
            Text(store.images.isEmpty ? "W tym folderze nie ma zdjęć PNG ani JPG." : "Wybierz zdjęcie z listy.")
                .font(Theme.text(14))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.sunken)
        }
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
                .help("Otwórz inny folder ze skanami (⌘O)")
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
            Picker("Format eksportu", selection: $store.format) {
                ForEach(ExportFormat.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Format plików z wycinkami")
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
                .help("Zapisz wszystkie boxy jako osobne pliki w folderze \(Exporter.folderName) (⌘E)")
            }
        }
    }
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
            Text(image)
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
            Button("Otwórz folder ze skanami…") { store.isPickingFolder = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
            Text("albo przeciągnij folder tutaj")
                .font(Theme.text(12))
                .foregroundStyle(Theme.muted)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
    }
}
