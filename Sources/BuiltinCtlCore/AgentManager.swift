import Darwin
import Foundation

public enum AgentManagerError: LocalizedError {
    case command(String)

    public var errorDescription: String? {
        switch self {
        case .command(let detail): return detail
        }
    }
}

public struct AgentManager {
    private struct LaunchctlResult {
        let status: Int32
        let stdout: String
        let stderr: String

        var detail: String {
            let error = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !error.isEmpty { return error }
            return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public static let label = "io.github.builtinctl.auto"

    public static var applicationDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/builtinctl", isDirectory: true)
    }
    public static var installedExecutable: URL {
        applicationDirectory.appendingPathComponent("bin/builtinctl")
    }
    public static var runtimeVersionsDirectory: URL {
        applicationDirectory.appendingPathComponent("bin/versions", isDirectory: true)
    }
    public static var updateSourceURL: URL {
        applicationDirectory.appendingPathComponent("update-source")
    }
    public static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/builtinctl", isDirectory: true)
    }
    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private var domain: String { "gui/\(getuid())" }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.plistURL.path)
    }

    public init() {}

    public func install(executable source: URL) throws {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: source.path) else {
            throw AgentManagerError.command("Current builtinctl executable is not readable and executable: \(source.path)")
        }

        // Stop an older loaded copy before replacing its executable. bootout sends
        // SIGTERM, allowing its normal restoration path to run.
        try stopAgentIfLoaded()

        try manager.createDirectory(
            at: Self.installedExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try manager.createDirectory(at: Self.logsDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: Self.plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let binary = try Data(contentsOf: source)
        try binary.write(to: Self.installedExecutable, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.installedExecutable.path)
        try Self.configureUpdateSource(for: source, fileManager: manager)

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: Self.propertyList(),
            format: .xml,
            options: 0
        )
        try plistData.write(to: Self.plistURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.plistURL.path)

        try? manager.removeItem(at: BuiltinCtlPaths.pid)
        try launchctl(["bootstrap", domain, Self.plistURL.path])
        try waitForAgentStart()
    }

    static func propertyList() -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [Self.installedExecutable.path, "_launch-auto"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
            "WorkingDirectory": Self.applicationDirectory.path,
            "StandardOutPath": Self.logsDirectory.appendingPathComponent("builtinctl.log").path,
            "StandardErrorPath": Self.logsDirectory.appendingPathComponent("builtinctl-error.log").path,
        ]
    }

    public func uninstall() throws {
        let manager = FileManager.default
        try stopAgentIfLoaded()
        if manager.fileExists(atPath: Self.plistURL.path) {
            try manager.removeItem(at: Self.plistURL)
        }
        if manager.fileExists(atPath: Self.applicationDirectory.path) {
            try manager.removeItem(at: Self.applicationDirectory)
        }
    }

    /// Prepare a persistent runtime copy of the currently linked Homebrew
    /// executable. The running controller and all of its helpers then use this
    /// immutable copy even if Homebrew cleans up the old Cellar during upgrade.
    public static func prepareAutomaticExecutable(
        fileManager manager: FileManager = .default,
        fallback: URL = installedExecutable,
        sourceRecordURL: URL = AgentManager.updateSourceURL,
        versionsDirectory: URL = AgentManager.runtimeVersionsDirectory
    ) throws -> URL {
        guard manager.fileExists(atPath: sourceRecordURL.path),
              let text = try? String(contentsOf: sourceRecordURL),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }

        let source = URL(
            fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard manager.isExecutableFile(atPath: source.path) else { return fallback }
        let resolved = source.resolvingSymlinksInPath()
        guard let identifier = homebrewVersionIdentifier(for: resolved) else { return fallback }

        let runtime = versionsDirectory
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("builtinctl")
        try manager.createDirectory(
            at: runtime.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let sourceData = try Data(contentsOf: resolved)
        let runtimeData = try? Data(contentsOf: runtime)
        if runtimeData != sourceData {
            try sourceData.write(to: runtime, options: .atomic)
        }
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
        guard manager.isExecutableFile(atPath: runtime.path) else {
            throw AgentManagerError.command("Prepared agent executable is not executable: \(runtime.path)")
        }
        return runtime
    }

    static func stableHomebrewExecutable(for source: URL) -> URL? {
        let resolved = source.standardizedFileURL.resolvingSymlinksInPath()
        let marker = "/Cellar/builtinctl/"
        guard let range = resolved.path.range(of: marker) else { return nil }
        let prefix = String(resolved.path[..<range.lowerBound])
        guard !prefix.isEmpty else { return nil }
        return URL(fileURLWithPath: prefix, isDirectory: true)
            .appendingPathComponent("opt/builtinctl/bin/builtinctl")
    }

    static func homebrewVersionIdentifier(for source: URL) -> String? {
        let components = source.standardizedFileURL.pathComponents
        guard let cellar = components.firstIndex(of: "Cellar"),
              components.indices.contains(cellar + 2),
              components[cellar + 1] == "builtinctl" else { return nil }
        let version = components[cellar + 2]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard !version.isEmpty, version.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return version
    }

    private static func configureUpdateSource(
        for source: URL,
        fileManager manager: FileManager
    ) throws {
        guard let stable = stableHomebrewExecutable(for: source),
              manager.isExecutableFile(atPath: stable.path),
              stable.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() else {
            if manager.fileExists(atPath: updateSourceURL.path) {
                try manager.removeItem(at: updateSourceURL)
            }
            return
        }
        try Data("\(stable.path)\n".utf8).write(to: updateSourceURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: updateSourceURL.path)
    }

    /// Remove all per-user builtinctl data after the caller has restored and
    /// verified the built-in display. Configuration is removed last so the
    /// suspension sentinel survives any partial cleanup failure.
    public func purge() throws {
        try uninstall()
        try Self.removeResidualData()
    }

    static func removeResidualData(
        fileManager manager: FileManager = .default,
        applicationDirectory: URL = Self.applicationDirectory,
        logsDirectory: URL = Self.logsDirectory,
        configDirectory: URL = BuiltinCtlPaths.configDirectory
    ) throws {
        for directory in [applicationDirectory, logsDirectory, configDirectory] {
            if manager.fileExists(atPath: directory.path) {
                try manager.removeItem(at: directory)
            }
        }
    }

    private func stopAgentIfLoaded() throws {
        let target = "\(domain)/\(Self.label)"
        let bootout = try runLaunchctl(["bootout", target])
        let verification = try runLaunchctl(["print", target])

        if Self.serviceIsMissing(status: verification.status, output: verification.detail) {
            return
        }
        if verification.status == 0 {
            let reason = bootout.detail.isEmpty ? "launchctl still reports it as loaded" : bootout.detail
            throw AgentManagerError.command(
                "LaunchAgent could not be stopped; refusing to remove recovery files: \(reason)"
            )
        }
        throw AgentManagerError.command(
            "Could not verify that the LaunchAgent stopped; refusing to remove recovery files: \(verification.detail)"
        )
    }

    private func waitForAgentStart(timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let text = try? String(contentsOf: BuiltinCtlPaths.pid),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               kill(pid, 0) == 0 {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw AgentManagerError.command("LaunchAgent did not report a running process within \(Int(timeout)) seconds.")
    }

    static func serviceIsMissing(status: Int32, output: String) -> Bool {
        status == 113 && output.localizedCaseInsensitiveContains("could not find service")
    }

    @discardableResult
    private func launchctl(_ arguments: [String]) throws -> String {
        let result = try runLaunchctl(arguments)
        guard result.status == 0 else {
            throw AgentManagerError.command(
                result.detail.isEmpty ? "launchctl failed with status \(result.status)." : result.detail
            )
        }
        return result.stdout
    }

    private func runLaunchctl(_ arguments: [String]) throws -> LaunchctlResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationReason == .exit else {
            throw AgentManagerError.command(
                "launchctl terminated abnormally."
            )
        }
        return LaunchctlResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
