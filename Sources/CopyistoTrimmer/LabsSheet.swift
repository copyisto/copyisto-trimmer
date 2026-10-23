import SwiftUI

/// Pull a submission to cut and push the work back, without the terminal; the `copyisto` CLI does the work.
struct LabsSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pullCode = ""
    @State private var pushed = false
    @State private var awaitingConfirmation = false

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
                if let submission = store.submission {
                    submissionSection(submission)
                } else {
                    Text("„\(folder.lastPathComponent)” nie jest folderem zgłoszenia, więc nie ma dokąd go wysłać. Pobierz zgłoszenie powyżej i przenieś skany do folderu jego zeszytu, np. nowy/.")
                        .font(Theme.text(12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        let code = Labs.parse(pullCode)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Pobierz zgłoszenie do cięcia").font(Theme.text(13, weight: .semibold))
            HStack {
                TextField("Kod zgłoszenia albo zeszytu, np. M4K-V albo M4K-V-01", text: $pullCode)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(pull)
                Button("Pobierz", action: pull)
                    .disabled(!signedIn || busy || code == nil)
            }
            Text("Do ~/Trimmer/\(code?.submission ?? "<kod>") (copyisto init, potem copyisto pull), potem folder otworzy się tutaj. Twoich niewysłanych zmian pobieranie nie nadpisze.")
                .font(Theme.text(11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submissionSection(_ submission: Submission) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Zgłoszenie \(submission.code)").font(Theme.text(13, weight: .semibold))
            HStack {
                Button {
                    Task { await push(submission, force: false) }
                } label: {
                    Label("Eksportuj i wyślij", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!signedIn || busy)
                Button("Pobierz zmiany") { Task { await pullChanges(submission) } }
                    .disabled(!signedIn || busy)
                if pushed { Label("Wysłane", systemImage: "checkmark").foregroundStyle(Theme.accent) }
            }
            if awaitingConfirmation {
                VStack(alignment: .leading, spacing: 8) {
                    Text("copyisto push pyta o to, co wypisał niżej. Nic jeszcze nie wysłano.")
                        .font(Theme.text(12, weight: .medium))
                    HStack {
                        Button("Potwierdź i wyślij") { Task { await push(submission, force: true) } }
                            .disabled(busy)
                        Button("Nie wysyłaj") { awaitingConfirmation = false }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warningSoft, in: .rect(cornerRadius: 6))
            }
            Text(store.isSubmissionRoot
                ? "Najpierw eksport (⌘E) zmienionych zeszytów, potem copyisto push: skany, opis i wycinki."
                : "Najpierw eksport (⌘E), potem copyisto push tego zeszytu: skany, opis i wycinki.")
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

    private func pull() {
        guard let code = Labs.parse(pullCode), signedIn, !busy else { return }
        Task {
            guard let folder = await labs.pull(code.submission, notebook: code.notebook) else { return }
            if store.folder == folder.standardizedFileURL { store.reload() } else { store.open(folder) }
            // Straight to the notebook asked for.
            if let number = code.notebook, let first = store.notebooks.first(where: { $0.name == number })?.images.first {
                store.current = first
            }
            dismiss()
        }
    }

    private func pullChanges(_ submission: Submission) async {
        pushed = false
        awaitingConfirmation = false
        _ = await labs.pull(in: submission)
        store.reload()
    }

    private func push(_ submission: Submission, force: Bool) async {
        pushed = false
        awaitingConfirmation = false
        guard await store.export(announce: false) else { return }
        // A notebook opened on its own pushes only itself.
        let notebooks = store.isSubmissionRoot ? [] : store.notebooks.map(\.name)
        switch await labs.push(in: submission, notebooks: notebooks, force: force) {
        case .sent: pushed = true
        case .needsConfirmation: awaitingConfirmation = true
        case .failed: break
        }
        store.reload()
    }
}
