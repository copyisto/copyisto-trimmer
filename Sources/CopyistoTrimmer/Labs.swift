import Foundation
import ImageIO
import Observation

/// Copyisto Labs through the `copyisto` command line tool, run as a child process.
/// The app itself still makes no network requests: the login, the server and the git-like checks
/// (a pull never overwrites local work, a push refuses a notebook changed on the server) all stay in the CLI.
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

    /// Where the pulled notebooks go, one folder each, as in the CLI's own examples.
    static let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Trimmer", directoryHint: .isDirectory)

    /// An app opened from Finder gets a bare PATH, so the places a Bun install or Homebrew puts tools are added.
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

    /// `copyisto raw pull`: the notebook's scans and earlier boxes into `~/Trimmer/<code>`; local changes are kept.
    func pull(_ code: String) async -> URL? {
        let folder = Self.root.appending(path: code, directoryHint: .isDirectory)
        // The CLI makes the folder itself, so a mistyped code leaves no empty one behind.
        guard let result = await run("Pobieranie \(code)", ["raw", "pull", code, folder.path]), result.status == 0
        else { return nil }
        return folder
    }

    /// `copyisto trims push`: the exported crops become the notebook's pages.
    /// A folder that is not a notebook's yet starts a new notebook in `submission`.
    func push(_ folder: URL, newIn submission: String?, deviceType: DeviceType) async -> Bool {
        var arguments = ["trims", "push", folder.path]
        if let submission {
            arguments += ["--id", submission, "--device-type", deviceType.rawValue]
            if let dpi = Self.dpi(in: folder) { arguments += ["--dpi", String(dpi)] }
        }
        return await run("Wysyłanie", arguments)?.status == 0
    }

    func cancel() {
        process?.terminate()
    }

    /// The notebook a folder belongs to, from the CLI's own files there (read only, never written).
    static func notebook(of folder: URL) -> String? {
        struct Origin: Decodable { let package_id: String }
        struct Upload: Decodable { let package: Origin? }
        let read = { (name: String) in try? Data(contentsOf: folder.appending(path: name)) }
        if let data = read(".copyisto-origin.json"), let origin = try? JSONDecoder().decode(Origin.self, from: data) {
            return origin.package_id
        }
        if let data = read(".copyisto-upload.json"), let upload = try? JSONDecoder().decode(Upload.self, from: data) {
            return upload.package?.package_id
        }
        return nil
    }

    /// The scans' resolution, for a new notebook's page description; pages from a pulled RAW carry their own.
    static func dpi(in folder: URL) -> Int? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let image = files.sorted().first { Store.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        guard let image, let source = CGImageSourceCreateWithURL(folder.appending(path: image) as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi > 72
        else { return nil }
        return Int(dpi.rounded())
    }

    /// Runs the tool and collects its output; a title shows the command in the sheet with its log, nil runs it quietly.
    private func run(_ title: String?, _ arguments: [String]) async -> (status: Int32, lines: [String])? {
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

        if let title {
            running = title
            log = []
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

enum DeviceType: String, CaseIterable {
    case scanner, camera, other

    var label: String {
        switch self {
        case .scanner: "Skaner"
        case .camera: "Aparat"
        case .other: "Inne"
        }
    }
}
