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
        _ = try? launchctl(["bootout", "\(domain)/\(Self.label)"])

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
        _ = try? launchctl(["bootout", "\(domain)/\(Self.label)"])
        if manager.fileExists(atPath: Self.plistURL.path) {
            try manager.removeItem(at: Self.plistURL)
        }
        if manager.fileExists(atPath: Self.installedExecutable.path) {
            try manager.removeItem(at: Self.installedExecutable)
        }
    }

    @discardableResult
    private func launchctl(_ arguments: [String]) throws -> String {
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
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentManagerError.command(
                detail.isEmpty ? "launchctl failed with status \(process.terminationStatus)." : detail
            )
        }
        return stdout
    }
}
