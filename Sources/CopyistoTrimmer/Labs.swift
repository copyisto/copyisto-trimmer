import Foundation
import Observation

/// Copyisto Labs through the `copyisto` command line tool, run as a child process.
/// The app itself still makes no network requests: the login, the server and the git-like checks
/// (a pull never overwrites local work, a push asks before replacing other people's changes) all stay in the CLI.
@MainActor @Observable
final class Labs {
    enum Account: Equatable {
        case unknown
        case signedIn(String)
        case signedOut(String)
        /// No `copyisto` in any of the usual places.
        case missing
    }

    private(set) var account = Account.unknown
    /// What the tool printed for the current or last command, line by line.
    private(set) var log: [String] = []
    /// The running command's title; nil when idle.
    private(set) var running: String?
    private var process: Process?

    /// Where pulled submissions go, one folder each, as in the CLI's own examples.
    static let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Trimmer", directoryHint: .isDirectory)

    /// The app opened from Finder gets a bare PATH, so the places a Bun install or Homebrew puts tools are added.
    /// The CLI from a checkout is a `#!/usr/bin/env bun` script, so bun must be found on the same PATH.
    private static var searchPath: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return Tags.merged(inherited, ["\(home)/.bun/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
    }

    static func executable() -> URL? {
        searchPath.map { URL(filePath: $0).appending(path: "copyisto") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func checkAccount() async {
        guard let result = await run(nil, ["whoami"]) else { return }
        let first = result.lines.first ?? ""
        account = result.status == 0 ? .signedIn(first) : .signedOut(first)
    }

    /// Prints a code to approve in the browser, which the CLI opens, and waits for it.
    func login() async {
        _ = await run("Logowanie", ["login"])
        await checkAccount()
    }

    /// The submission and the notebook a typed code names: `M4K-V`, or `M4K-V-01` for that notebook only.
    static func parse(_ text: String) -> (submission: String, notebook: String?)? {
        let code = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard let match = code.wholeMatch(of: /([A-Z0-9]+-[A-Z0-9])(?:-(\d{2,3}))?/) else { return nil }
        return (String(match.1), match.2.map(String.init))
    }

    /// `copyisto init` the first time, then `copyisto pull`: the submission into `~/Trimmer/<code>`, as a git clone.
    /// Local changes are kept; the CLI reports what it left alone.
    func pull(_ submission: String, notebook: String?) async -> URL? {
        let folder = Self.root.appending(path: submission, directoryHint: .isDirectory)
        let isNew = Submission.of(folder)?.isRoot != true
        if isNew {
            // A folder from before submissions were repositories holds one notebook's files at the top,
            // which init would leave outside every notebook.
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            if !existing.isEmpty {
                log = ["\(folder.path) już istnieje i nie jest folderem zgłoszenia. Przenieś go albo zmień jego nazwę, a potem pobierz ponownie."]
                return nil
            }
            // The CLI makes the folder itself, so a mistyped code leaves no empty one behind.
            guard await run("Pobieranie \(submission)", ["init", submission, folder.path])?.status == 0 else { return nil }
        }
        let title = "Pobieranie \(notebook.map { "\(submission)-\($0)" } ?? submission)"
        guard await run(title, ["pull"] + (notebook.map { [$0] } ?? []), in: folder, keepingLog: isNew)?.status == 0 else { return nil }
        return folder
    }

    /// `copyisto pull` in an open submission.
    func pull(in submission: Submission) async -> Bool {
        await run("Pobieranie zmian", ["pull"], in: submission.root)?.status == 0
    }

    enum PushResult {
        case sent, failed
        /// The CLI lists what it would ask about (a new notebook, files leaving the RAW, other people's versions
        /// replaced) and stops, since nobody can answer without a terminal; `--force` is the answer yes.
        case needsConfirmation
    }

    /// `copyisto push`: the RAW, the description and the exported crops, of `notebooks` or of every notebook.
    func push(in submission: Submission, notebooks: [String], force: Bool) async -> PushResult {
        let arguments = ["push"] + notebooks + (force ? ["--force"] : [])
        guard let result = await run(force ? "Wysyłanie po potwierdzeniu" : "Wysyłanie", arguments, in: submission.root) else { return .failed }
        if result.status == 0 { return .sent }
        return result.lines.contains { $0.contains("Nie ma kogo zapytać") } ? .needsConfirmation : .failed
    }

    func cancel() {
        process?.terminate()
    }

    /// Runs the tool and collects its output; a title shows the command in the sheet with its log, nil runs it quietly.
    /// The CLI finds the submission from its working directory, as git does.
    private func run(
        _ title: String?, _ arguments: [String], in directory: URL? = nil, keepingLog: Bool = false
    ) async -> (status: Int32, lines: [String])? {
        guard running == nil else { return nil }
        guard let tool = Self.executable() else {
            account = .missing
            return nil
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.searchPath.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        if let directory { process.currentDirectoryURL = directory }

        if let title {
            running = title
            if !keepingLog { log = [] }
        }
        self.process = process
        defer {
            self.process = nil
            if title != nil { running = nil }
        }

        // Read while the tool runs, so its progress shows as it happens.
        let reader = Task { @MainActor in
            var lines: [String] = []
            for try await line in pipe.fileHandleForReading.bytes.lines {
                lines.append(line)
                if title != nil { log.append(line) }
            }
            return lines
        }
        do {
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
            return (status, (try? await reader.value) ?? [])
        } catch {
            reader.cancel()
            log.append("Nie udało się uruchomić \(tool.path): \(error.localizedDescription)")
            return nil
        }
    }
}
