import Darwin
import Foundation

public enum ExecutableLocator {
    /// Return the executable that macOS actually launched. `argv[0]` may only be
    /// a command name when a shell found builtinctl through PATH, so it is not a
    /// reliable source path for installing the agent or spawning helpers.
    public static func current() -> URL {
        resolve(
            reportedExecutablePath: platformExecutablePath(),
            argument0: CommandLine.arguments[0],
            currentDirectoryPath: FileManager.default.currentDirectoryPath,
            environmentPath: ProcessInfo.processInfo.environment["PATH"]
        )
    }

    static func resolve(
        reportedExecutablePath: String?,
        argument0: String,
        currentDirectoryPath: String,
        environmentPath: String?
    ) -> URL {
        if let reportedExecutablePath, !reportedExecutablePath.isEmpty {
            return canonicalURL(
                path: reportedExecutablePath,
                currentDirectoryPath: currentDirectoryPath
            )
        }

        if argument0.contains("/") {
            return canonicalURL(path: argument0, currentDirectoryPath: currentDirectoryPath)
        }

        if let environmentPath {
            for directory in environmentPath.split(separator: ":", omittingEmptySubsequences: false) {
                let base = directory.isEmpty ? currentDirectoryPath : String(directory)
                let candidate = URL(fileURLWithPath: base, isDirectory: true)
                    .appendingPathComponent(argument0)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate.standardizedFileURL.resolvingSymlinksInPath()
                }
            }
        }

        return canonicalURL(path: argument0, currentDirectoryPath: currentDirectoryPath)
    }

    private static func canonicalURL(path: String, currentDirectoryPath: String) -> URL {
        URL(
            fileURLWithPath: path,
            relativeTo: URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
        ).standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func platformExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(size))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &size)
        }
        guard result == 0 else { return nil }
        return String(cString: buffer)
    }
}
