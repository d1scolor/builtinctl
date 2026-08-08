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
    public static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/builtinctl", isDirectory: true)
    }
    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private var domain: String { "gui/\(getuid())" }

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

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: Self.propertyList(),
            format: .xml,
            options: 0
        )
        try plistData.write(to: Self.plistURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.plistURL.path)

        try launchctl(["bootstrap", domain, Self.plistURL.path])
    }

    static func propertyList() -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [Self.installedExecutable.path, "auto"],
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
        if manager.fileExists(atPath: Self.installedExecutable.path) {
            try manager.removeItem(at: Self.installedExecutable)
        }
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
