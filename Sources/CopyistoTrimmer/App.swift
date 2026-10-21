import AppKit
import SwiftUI

@main
struct CopyistoTrimmerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var store = Store()

    var body: some Scene {
        Window("Copyisto Trimmer", id: "main") {
            ContentView()
                .environment(store)
                // Room for the list, a usable page and the inspector side by side.
                .frame(minWidth: 1000, minHeight: 560)
        }
        .defaultSize(width: 1400, height: 1000)
        .commands { AppCommands(store: store) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets `swift run` bring up a normal foreground app; the bundled .app does this anyway.
        NSApp.setActivationPolicy(.regular)
        // One window, no tabs; this also keeps ⌘T free for the box's tags.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct AppCommands: Commands {
    let store: Store

    private var typing: Bool { store.editing != nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Otwórz folder…") { store.isPickingFolder = true }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Cofnij") { store.undo() }
                .keyboardShortcut("z")
                // In a text field it undoes the typing, which has its own history.
                .disabled(!store.canUndo && store.editing == nil)
            Button("Ponów") { store.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!store.canRedo && store.editing == nil)
        }
        CommandGroup(before: .toolbar) {
            Button("Powiększ") { store.zoomIn() }
                .keyboardShortcut("+")
                .disabled(store.zoom >= Store.zoomSteps.last!)
            Button("Pomniejsz") { store.zoomOut() }
                .keyboardShortcut("-")
                .disabled(store.zoom <= 1)
            Button("Dopasuj do okna") { store.zoomToFit() }
                .keyboardShortcut("0")
                .disabled(store.zoom == 1)
            Divider()
            Button(store.showsInspector ? "Ukryj tagi i uwagi" : "Pokaż tagi i uwagi") { store.showsInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Zdjęcie") {
            // Shortcuts without ⌘ would fire even in a text field, so they are off while one is typed in.
            Button("Poprzednie zdjęcie") { store.step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!store.canStep(-1) || typing)
            Button("Następne zdjęcie") { store.step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!store.canStep(1) || typing)
            Divider()
            Button("Obróć w lewo o 0,1°") { store.rotateCurrent(by: -Store.rotationStep) }
                .keyboardShortcut("[", modifiers: [])
                .disabled(store.current == nil || typing)
            Button("Obróć w prawo o 0,1°") { store.rotateCurrent(by: Store.rotationStep) }
                .keyboardShortcut("]", modifiers: [])
                .disabled(store.current == nil || typing)
            Button("Wyprostuj automatycznie") { Task { await store.straightenCurrent() } }
                .keyboardShortcut("l")
                .disabled(store.current == nil || store.isStraightening)
            Button("Bez obrotu") { store.resetRotation() }
                .disabled(store.current.map(store.rotation(of:)) ?? 0 == 0)
            Divider()
            Button("Usuń zaznaczony box") { store.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(store.selectedBox == nil || typing)
            Button("Odznacz") { store.selectedBox = nil }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(store.selectedBox == nil || typing)
            Divider()
            Button("Tagi ramki") { store.describe(.boxTags) }
                .keyboardShortcut("t")
                .disabled(store.selectedBox == nil)
            Button("Uwaga ramki") { store.describe(.boxNote) }
                .keyboardShortcut("u")
                .disabled(store.selectedBox == nil)
            Button("Tagi strony") { store.describe(.pageTags) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(store.current == nil)
            Button("Uwaga strony") { store.describe(.pageNote) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(store.current == nil)
            Button("Tagi folderu") { store.describe(.folderTags) }
                // ⌥⌘T is the system's Show/Hide Toolbar.
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(store.folder == nil)
            Divider()
            Button("Eksportuj") { Task { await store.export() } }
                .keyboardShortcut("e")
                .disabled(store.folder == nil || store.isExporting || store.totalBoxes == 0)
        }
    }
}
