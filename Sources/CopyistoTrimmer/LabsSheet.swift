import SwiftUI

/// Pull a notebook to cut and push the crops back, without the terminal; the `copyisto` CLI does the work.
struct LabsSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pullCode = ""
    @State private var submission = ""
    @State private var deviceType = DeviceType.scanner
    @State private var pushed = false

    private var labs: Labs { store.labs }
    private var signedIn: Bool { if case .signedIn = labs.account { true } else { false } }
    private var busy: Bool { labs.running != nil || store.isExporting }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Copyisto Labs")
                .font(Theme.display(22))
                .foregroundStyle(Theme.text)
            account
            Divider()
            pullSection
            if let folder = store.folder {
                Divider()
                pushSection(folder)
            }
            if labs.running != nil || !labs.log.isEmpty {
                output
            }
            HStack {
                Spacer()
                Button("Zamknij") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.paper)
        .task { await labs.checkAccount() }
    }

    @ViewBuilder
    private var account: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch labs.account {
            case .unknown:
                ProgressView().controlSize(.small)
                Text("Sprawdzam logowanie (copyisto whoami)…").foregroundStyle(Theme.muted)
                Spacer()
            case .signedIn(let who):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                Text(who).foregroundStyle(Theme.text).textSelection(.enabled)
                Spacer()
                Button("Sprawdź ponownie") { Task { await labs.checkAccount() } }
                    .disabled(busy)
            case .signedOut(let message):
                Image(systemName: "person.crop.circle.badge.xmark").foregroundStyle(Theme.warning)
                Text(message).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Zaloguj") { Task { await labs.login() } }
                    .disabled(busy)
            case .missing:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                Text("Nie znaleziono polecenia copyisto (w ~/.bun/bin, /opt/homebrew/bin ani /usr/local/bin). Zainstaluj Copyisto CLI i otwórz to okno ponownie.")
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Theme.text(13))
    }

    private var pullSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pobierz zeszyt do cięcia").font(Theme.text(13, weight: .semibold))
            HStack {
                TextField("Zeszyt albo zgłoszenie, np. M4K-V-01", text: $pullCode)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(pull)
                Button("Pobierz", action: pull)
                    .disabled(!signedIn || busy || code(pullCode) == nil)
            }
            Text("Do ~/Trimmer/\(code(pullCode) ?? "<kod>"), potem folder otworzy się tutaj. Twoich niewysłanych zmian pobieranie nie nadpisze.")
                .font(Theme.text(11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pushSection(_ folder: URL) -> some View {
        let notebook = Labs.notebook(of: folder)
        let target = notebook == nil ? code(submission) : nil
        return VStack(alignment: .leading, spacing: 8) {
            Text("Wyślij wycinki").font(Theme.text(13, weight: .semibold))
            if let notebook {
                Text("„\(folder.lastPathComponent)” to zeszyt \(notebook): wycinki zastąpią jego strony, a niezmienione ramki zachowają swoje.")
                    .font(Theme.text(12))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    TextField("Kod zgłoszenia, np. M4K-V", text: $submission)
                        .textFieldStyle(.roundedBorder)
                    Picker("Urządzenie", selection: $deviceType) {
                        ForEach(DeviceType.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                }
                Text("„\(folder.lastPathComponent)” będzie nowym zeszytem w tym zgłoszeniu\(Labs.dpi(in: folder).map { ", \($0) dpi z plików" } ?? "").")
                    .font(Theme.text(11))
                    .foregroundStyle(Theme.muted)
            }
            HStack {
                Button {
                    Task { await push(folder, newIn: target) }
                } label: {
                    Label("Eksportuj i wyślij", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!signedIn || busy || (notebook == nil && target == nil))
                if pushed { Label("Wysłane", systemImage: "checkmark").foregroundStyle(Theme.accent) }
            }
            Text("Najpierw eksport (⌘E) do \(Exporter.folderName), potem copyisto trims push.")
                .font(Theme.text(11))
                .foregroundStyle(Theme.muted)
        }
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let running = labs.running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(running)…").font(Theme.text(12))
                    Spacer()
                    Button("Przerwij") { labs.cancel() }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(labs.log.enumerated()), id: \.offset) { index, line in
                            Text(line).id(index)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 160)
                .background(Theme.surface, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                .onChange(of: labs.log.count) { proxy.scrollTo(labs.log.count - 1, anchor: .bottom) }
            }
        }
    }

    /// Codes are upper case without spaces; anything else is not one, and the CLI would say so less kindly.
    private func code(_ text: String) -> String? {
        let code = text.trimmingCharacters(in: .whitespaces).uppercased()
        return code.range(of: #"^[A-Z0-9]+(-[A-Z0-9]+)+$"#, options: .regularExpression) == nil ? nil : code
    }

    private func pull() {
        guard let code = code(pullCode), signedIn, !busy else { return }
        Task {
            if let folder = await labs.pull(code) {
                store.open(folder)
                dismiss()
            }
        }
    }

    private func push(_ folder: URL, newIn submission: String?) async {
        pushed = false
        guard await store.export(announce: false) else { return }
        pushed = await labs.push(folder, newIn: submission, deviceType: deviceType)
    }
}
