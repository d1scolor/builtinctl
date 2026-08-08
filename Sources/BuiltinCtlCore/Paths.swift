import Foundation
import Darwin

public enum BuiltinCtlPaths {
    public static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/builtinctl", isDirectory: true)
    }
    public static var disabled: URL { configDirectory.appendingPathComponent("disabled") }
    public static var builtinDisplayID: URL { configDirectory.appendingPathComponent("builtin-display-id") }
    public static var disabledState: URL { configDirectory.appendingPathComponent("builtin-disabled") }
    public static var lock: URL { configDirectory.appendingPathComponent("auto.lock") }
    public static var mutationLock: URL { configDirectory.appendingPathComponent("display.lock") }
    public static var pid: URL { configDirectory.appendingPathComponent("auto.pid") }
    public static var started: URL { configDirectory.appendingPathComponent("auto.started") }
    public static var safeUntil: URL { configDirectory.appendingPathComponent("auto.safe-until") }
    public static var agentVersion: URL { configDirectory.appendingPathComponent("auto.version") }
    public static var rearmRequest: URL { configDirectory.appendingPathComponent("auto.rearm") }
    public static var recoveryLatch: URL { configDirectory.appendingPathComponent("auto.recovery-latched") }

    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    }

    public static var isSuspended: Bool {
        FileManager.default.fileExists(atPath: disabled.path)
    }

    public static var hasDisabledState: Bool {
        FileManager.default.fileExists(atPath: disabledState.path)
    }

    public static var isRecoveryLatched: Bool {
        FileManager.default.fileExists(atPath: recoveryLatch.path)
    }

    public static func writeAtomically(_ text: String, to url: URL) throws {
        try ensureDirectory()
        guard let data = text.data(using: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()

        // Persist the atomic rename as well as the file contents.
        let directoryFD = open(url.deletingLastPathComponent().path, O_RDONLY)
        if directoryFD >= 0 {
            _ = fsync(directoryFD)
            close(directoryFD)
        }
    }

    public static func suspend(reason: String = "user") throws {
        try writeAtomically("\(reason)\n", to: disabled)
    }

    static func suspendForUncleanExit(identity: SystemSessionIdentity?) throws {
        let marker = CrashSuspensionMarker(identity: identity)
        let data = try JSONEncoder().encode(marker)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try writeAtomically("\(text)\n", to: disabled)
    }

    public static func markBuiltinDisabled() throws {
        let marker = DisabledStateMarker(identity: try? SystemSessionIdentity.current())
        let data = try JSONEncoder().encode(marker)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try writeAtomically("\(text)\n", to: disabledState)
    }

    static func disabledStateOrigin(
        currentIdentity: SystemSessionIdentity? = try? SystemSessionIdentity.current()
    ) -> DisabledStateOrigin {
        guard let data = try? Data(contentsOf: disabledState) else { return .unknown }
        return BuiltinCtlCore.disabledStateOrigin(
            markerData: data,
            currentIdentity: currentIdentity
        )
    }

    static func crashSuspensionOrigin(
        currentIdentity: SystemSessionIdentity?
    ) -> DisabledStateOrigin? {
        guard let data = try? Data(contentsOf: disabled) else { return nil }
        return BuiltinCtlCore.crashSuspensionOrigin(
            markerData: data,
            currentIdentity: currentIdentity
        )
    }

    static func clearPriorCrashSuspension(
        currentIdentity: SystemSessionIdentity?
    ) throws -> Bool {
        guard crashSuspensionOrigin(currentIdentity: currentIdentity) == .priorSession else {
            return false
        }
        try FileManager.default.removeItem(at: disabled)
        return true
    }

    public static func clearBuiltinDisabledMarker() throws {
        if FileManager.default.fileExists(atPath: disabledState.path) {
            try FileManager.default.removeItem(at: disabledState)
        }
    }

    public static func requestRearm() throws {
        try writeAtomically("\(Date().timeIntervalSince1970)\n", to: rearmRequest)
    }

    static func consumeRearmRequest(startedAt: Date) throws -> Bool {
        guard FileManager.default.fileExists(atPath: rearmRequest.path) else { return false }
        let text = try String(contentsOf: rearmRequest)
        defer { try? FileManager.default.removeItem(at: rearmRequest) }
        return rearmRequestIsCurrent(text, startedAt: startedAt)
    }

    static func rearmRequestIsCurrent(_ text: String, startedAt: Date) -> Bool {
        guard let requestedAt = TimeInterval(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else { return false }
        return requestedAt >= startedAt.timeIntervalSince1970
    }

    public static func markRecoveryLatched() throws {
        try writeAtomically("latched\n", to: recoveryLatch)
    }

    public static func clearRecoveryLatch() throws {
        if FileManager.default.fileExists(atPath: recoveryLatch.path) {
            try FileManager.default.removeItem(at: recoveryLatch)
        }
    }
}

public enum ProcessLockError: LocalizedError {
    case alreadyRunning(String)
    case openFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning(let purpose): return "another \(purpose) is already running."
        case .openFailed(let code): return "could not open automation lock (errno \(code))."
        }
    }
}

public final class ProcessLock {
    private var descriptor: Int32 = -1

    public init(url: URL, purpose: String = "operation") throws {
        descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ProcessLockError.openFailed(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            throw ProcessLockError.alreadyRunning(purpose)
        }
    }

    deinit {
        if descriptor >= 0 {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}
