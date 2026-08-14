import CoreGraphics
import Darwin
import Foundation

public struct DisplaySnapshot {
    public let online: [CGDirectDisplayID]
    public let active: [CGDirectDisplayID]
    public let builtin: CGDirectDisplayID?

    public var activeExternals: [CGDirectDisplayID] {
        active.filter {
            CGDisplayIsBuiltin($0) == 0 && !DisplayIdentity.isUnplugPlaceholder($0)
        }
    }

    public var sleepingExternals: [CGDirectDisplayID] {
        online.filter {
            CGDisplayIsBuiltin($0) == 0
                && !DisplayIdentity.isUnplugPlaceholder($0)
                && CGDisplayIsAsleep($0) != 0
        }
    }

    public var builtinActive: Bool {
        guard let builtin else { return false }
        return active.contains(builtin)
    }
}

public enum DisplayError: LocalizedError {
    case enumeration(CGError)
    case builtinNotFound
    case privateAPIUnavailable
    case noActiveExternal
    case configuration(CGError)
    case recoveryCache(String)
    case automationSuspended
    case clamshellClosed
    case postcondition(String)

    public var errorDescription: String? {
        switch self {
        case .enumeration(let error): return "CoreGraphics display enumeration failed (\(error.rawValue))."
        case .builtinNotFound: return "Built-in display was not found."
        case .privateAPIUnavailable: return "CGSConfigureDisplayEnabled is unavailable on this macOS version."
        case .noActiveExternal: return "refusing to disable built-in display because no active external display was found."
        case .configuration(let error): return "Display configuration failed (\(error.rawValue))."
        case .recoveryCache(let detail): return "Built-in display recovery ID is not durable: \(detail)"
        case .automationSuspended: return "automatic switching is suspended."
        case .clamshellClosed: return "the laptop lid is closed; open it before changing the built-in display."
        case .postcondition(let detail): return "Display safety verification failed: \(detail)"
        }
    }
}

public final class DisplayController {
    private typealias ConfigureDisplayEnabled = @convention(c) (
        CGDisplayConfigRef?, CGDirectDisplayID, Bool
    ) -> CGError

    private let configureEnabled: ConfigureDisplayEnabled?

    public init() {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled") else {
            configureEnabled = nil
            return
        }
        configureEnabled = unsafeBitCast(symbol, to: ConfigureDisplayEnabled.self)
    }

    public var privateAPIAvailable: Bool { configureEnabled != nil }

    private func cachedBuiltinDisplay() -> CGDirectDisplayID? {
        guard let value = try? String(contentsOf: BuiltinCtlPaths.builtinDisplayID),
              let id = CGDirectDisplayID(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              CGDisplayIsBuiltin(id) != 0 else {
            return nil
        }
        return id
    }

    private func rememberBuiltinDisplay(_ id: CGDirectDisplayID) {
        guard CGDisplayIsBuiltin(id) != 0 else { return }
        try? BuiltinCtlPaths.writeAtomically("\(id)\n", to: BuiltinCtlPaths.builtinDisplayID)
    }

    private func requireDurableRecoveryID(_ id: CGDirectDisplayID) throws {
        guard CGDisplayIsBuiltin(id) != 0 else { throw DisplayError.builtinNotFound }
        do {
            try BuiltinCtlPaths.writeAtomically("\(id)\n", to: BuiltinCtlPaths.builtinDisplayID)
            guard cachedBuiltinDisplay() == id else {
                throw DisplayError.recoveryCache("read-back validation failed.")
            }
        } catch let error as DisplayError {
            throw error
        } catch {
            throw DisplayError.recoveryCache(error.localizedDescription)
        }
    }

    private func displayList(
        _ getter: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    ) throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var error = getter(0, nil, &count)
        guard error == .success else { throw DisplayError.enumeration(error) }
        guard count > 0 else { return [] }
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        error = getter(count, &displays, &count)
        guard error == .success else { throw DisplayError.enumeration(error) }
        return Array(displays.prefix(Int(count)))
    }

    public func snapshot() throws -> DisplaySnapshot {
        let online = try displayList(CGGetOnlineDisplayList)
        let active = try displayList(CGGetActiveDisplayList)
        let onlineBuiltin = online.first(where: { CGDisplayIsBuiltin($0) != 0 })
        if let onlineBuiltin { rememberBuiltinDisplay(onlineBuiltin) }
        return DisplaySnapshot(
            online: online,
            active: active,
            builtin: onlineBuiltin ?? cachedBuiltinDisplay()
        )
    }

    public func setBuiltinEnabled(
        _ enabled: Bool,
        requireAutomationAllowed: Bool = false
    ) throws {
        try BuiltinCtlPaths.ensureDirectory()
        let mutationLock = try ProcessLock(url: BuiltinCtlPaths.mutationLock, purpose: "display mutation")
        defer { withExtendedLifetime(mutationLock) {} }
        guard let configureEnabled else { throw DisplayError.privateAPIUnavailable }
        try ClamshellState.requireOpen()

        if !enabled && requireAutomationAllowed && BuiltinCtlPaths.isSuspended {
            throw DisplayError.automationSuspended
        }

        // This fresh query is intentionally part of the mutation path. Never act on callback state.
        let current = try snapshot()
        guard let builtin = current.builtin else { throw DisplayError.builtinNotFound }
        guard CGDisplayIsBuiltin(builtin) != 0 else { throw DisplayError.builtinNotFound }
        if !enabled && current.activeExternals.isEmpty { throw DisplayError.noActiveExternal }
        if current.builtinActive == enabled { return }

        let expectedExternalIDs = Set(current.activeExternals)
        if !enabled { try requireDurableRecoveryID(builtin) }

        var configuration: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&configuration)
        guard error == .success, let configuration else {
            throw DisplayError.configuration(error)
        }

        if !enabled {
            // Minimize the unavoidable query-to-commit race. The automatic kill
            // switch and real external topology are checked after beginning the
            // transaction and immediately before the private call.
            if requireAutomationAllowed && BuiltinCtlPaths.isSuspended {
                CGCancelDisplayConfiguration(configuration)
                throw DisplayError.automationSuspended
            }
            let verified: DisplaySnapshot
            do {
                verified = try snapshot()
            } catch {
                CGCancelDisplayConfiguration(configuration)
                throw error
            }
            guard verified.builtin == builtin,
                  verified.builtinActive,
                  !expectedExternalIDs.isDisjoint(with: Set(verified.activeExternals)) else {
                CGCancelDisplayConfiguration(configuration)
                throw DisplayError.noActiveExternal
            }
        }

        error = configureEnabled(configuration, builtin, enabled)
        guard error == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw DisplayError.configuration(error)
        }

        // Session-only is a core recovery guarantee: logout/reboot discards the change.
        error = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard error == .success else { throw DisplayError.configuration(error) }

        do {
            try verifyPostcondition(
                enabled: enabled,
                builtin: builtin,
                expectedExternalIDs: expectedExternalIDs
            )
        } catch {
            if !enabled {
                // A disappearing external during commit is fail-open. Use a fresh
                // transaction in this helper before returning an error.
                try? configureBuiltin(builtin, enabled: true)
            }
            throw error
        }
    }

    private func configureBuiltin(_ builtin: CGDirectDisplayID, enabled: Bool) throws {
        guard let configureEnabled else { throw DisplayError.privateAPIUnavailable }
        var configuration: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&configuration)
        guard error == .success, let configuration else { throw DisplayError.configuration(error) }
        error = configureEnabled(configuration, builtin, enabled)
        guard error == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw DisplayError.configuration(error)
        }
        error = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard error == .success else { throw DisplayError.configuration(error) }
    }

    private func verifyPostcondition(
        enabled: Bool,
        builtin: CGDirectDisplayID,
        expectedExternalIDs: Set<CGDirectDisplayID>
    ) throws {
        for attempt in 0..<6 {
            let verified = try snapshot()
            let builtinCorrect = verified.builtin == builtin && verified.builtinActive == enabled
            let externalSafe = enabled || !expectedExternalIDs.isDisjoint(with: Set(verified.activeExternals))
            if builtinCorrect && externalSafe { return }
            if attempt < 5 { Thread.sleep(forTimeInterval: 0.05) }
        }
        throw DisplayError.postcondition(
            enabled
                ? "built-in display did not become active."
                : "built-in remained active or the validating external disappeared."
        )
    }
}
