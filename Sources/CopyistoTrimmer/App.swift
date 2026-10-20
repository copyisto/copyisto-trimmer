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
                .frame(minWidth: 820, minHeight: 560)
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
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct AppCommands: Commands {
    let store: Store

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Otwórz folder…") { store.isPickingFolder = true }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Cofnij") { store.undo() }
                .keyboardShortcut("z")
                .disabled(!store.canUndo)
            Button("Ponów") { store.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!store.canRedo)
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
        }
        CommandMenu("Zdjęcie") {
            Button("Poprzednie zdjęcie") { store.step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!store.canStep(-1))
            Button("Następne zdjęcie") { store.step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!store.canStep(1))
            Divider()
            Button("Obróć w lewo o 0,1°") { store.rotateCurrent(by: -Store.rotationStep) }
                .keyboardShortcut("[", modifiers: [])
                .disabled(store.current == nil)
            Button("Obróć w prawo o 0,1°") { store.rotateCurrent(by: Store.rotationStep) }
                .keyboardShortcut("]", modifiers: [])
                .disabled(store.current == nil)
            Button("Wyprostuj automatycznie") { Task { await store.straightenCurrent() } }
                .keyboardShortcut("l")
                .disabled(store.current == nil || store.isStraightening)
            Button("Bez obrotu") { store.resetRotation() }
                .disabled(store.current.map(store.rotation(of:)) ?? 0 == 0)
            Divider()
            Button("Usuń zaznaczony box") { store.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(store.selectedBox == nil)
            Button("Odznacz") { store.selectedBox = nil }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(store.selectedBox == nil)
            Divider()
            Button("Eksportuj") { Task { await store.export() } }
                .keyboardShortcut("e")
                .disabled(store.folder == nil || store.isExporting || store.totalBoxes == 0)
        }
    }
}
