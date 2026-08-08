import BuiltinCtlCore
import CoreGraphics
import Darwin
import Dispatch
import Foundation

private let version = "0.1.4"

private func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

private struct DaemonState {
    let running: Bool
    let safeModeRemaining: Int?
    let version: String?
}

private func daemonState() -> DaemonState {
    guard let text = try? String(contentsOf: BuiltinCtlPaths.pid),
          let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          kill(pid, 0) == 0 else { return DaemonState(running: false, safeModeRemaining: nil, version: nil) }
    let safeUntil = (try? String(contentsOf: BuiltinCtlPaths.safeUntil))
        .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    let remaining = safeUntil.map {
        max(0, Int(ceil($0 - Date().timeIntervalSince1970)))
    }
    let agentVersion = (try? String(contentsOf: BuiltinCtlPaths.agentVersion))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return DaemonState(
        running: true,
        safeModeRemaining: remaining.flatMap { $0 > 0 ? $0 : nil },
        version: agentVersion?.isEmpty == false ? agentVersion : nil
    )
}

private func status(_ display: DisplayController) throws {
    let state = try display.snapshot()
    let daemon = daemonState()
    print("builtinctl \(version)\n")
    print("Built-in:")
    print("  ID:            \(state.builtin.map { String($0) } ?? "not found")")
    print("  Online:        \(yesNo(state.builtin.map { state.online.contains($0) } ?? false))")
    print("  Active:        \(yesNo(state.builtinActive))")
    print("  Main:          \(yesNo(state.builtin.map { CGDisplayIsMain($0) != 0 } ?? false))\n")
    print("External:")
    print("  Active count:  \(state.activeExternals.count)")
    print("  IDs:           \(state.activeExternals.map { String($0) }.joined(separator: ", ").nilIfEmpty ?? "none")\n")
    print("Automation:")
    print("  Suspended:     \(yesNo(BuiltinCtlPaths.isSuspended))")
    print("  Recovery pending: \(yesNo(BuiltinCtlPaths.hasDisabledState))")
    print("  Reconnect required: \(yesNo(BuiltinCtlPaths.isRecoveryLatched))")
    print("  Daemon:        \(daemon.running ? "running" : "stopped")")
    let agentVersion = daemon.running ? (daemon.version ?? "unknown (legacy agent)") : "not running"
    let updatePending: String
    if !daemon.running {
        updatePending = "no"
    } else if let runningVersion = daemon.version {
        updatePending = yesNo(runningVersion != version)
    } else {
        updatePending = "unknown"
    }
    print("  CLI version:   \(version)")
    print("  Agent version: \(agentVersion)")
    print("  Update pending: \(updatePending)")
    let safeMode = daemon.safeModeRemaining.map { "yes (\($0)s remaining)" } ?? "no"
    print("  Safe mode:     \(safeMode)\n")
    print("Private API:")
    print("  Available:     \(yesNo(display.privateAPIAvailable))")
}

private func flagNames(_ flags: CGDisplayChangeSummaryFlags) -> String {
    let values: [(CGDisplayChangeSummaryFlags, String)] = [
        (.beginConfigurationFlag, "begin"), (.movedFlag, "moved"), (.setMainFlag, "main"),
        (.setModeFlag, "mode"), (.addFlag, "added"), (.removeFlag, "removed"),
        (.enabledFlag, "enabled"), (.disabledFlag, "disabled"),
        (.mirrorFlag, "mirror"), (.unMirrorFlag, "unmirror"),
        (.desktopShapeChangedFlag, "shape")
    ]
    let names = values.compactMap { flags.contains($0.0) ? $0.1 : nil }
    return names.isEmpty ? "unknown(\(flags.rawValue))" : names.joined(separator: ",")
}

private func watch(_ display: DisplayController) throws -> Never {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let watcher = DisplayWatcher { id, flags in
        DispatchQueue.main.async {
            let snapshot = try? display.snapshot()
            let builtin = CGDisplayIsBuiltin(id) != 0
            let online = snapshot?.online.contains(id) ?? false
            let active = snapshot?.active.contains(id) ?? false
            print("\(formatter.string(from: Date())) display-change id=\(id) flags=\(flagNames(flags)) builtin=\(yesNo(builtin)) online=\(yesNo(online)) active=\(yesNo(active))")
            fflush(stdout)
        }
    }
    try watcher.start()
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    var signalSources: [DispatchSourceSignal] = []
    for number in [SIGINT, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { watcher.stop(); Darwin.exit(0) }
        source.resume()
        signalSources.append(source)
    }
    withExtendedLifetime((watcher, signalSources)) { dispatchMain() }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private func usage() {
    print("Usage: builtinctl <status|on|off|auto|suspend|recover|resume|watch|test-off|install-agent|restart-agent|uninstall-agent|purge>")
}

private func execAutomaticMode(_ executable: URL) throws -> Never {
    let values = [executable.path, "auto"]
    var pointers = values.map { strdup($0) }
    guard pointers.allSatisfy({ $0 != nil }) else {
        pointers.compactMap { $0 }.forEach { free($0) }
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOMEM),
            userInfo: [NSLocalizedDescriptionKey: "Could not allocate automatic-mode arguments."]
        )
    }
    defer { pointers.compactMap { $0 }.forEach { free($0) } }
    pointers.append(nil)
    pointers.withUnsafeMutableBufferPointer { arguments in
        _ = execv(arguments[0], arguments.baseAddress)
    }
    let code = errno
    throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code),
        userInfo: [NSLocalizedDescriptionKey: "Could not launch current agent executable: \(String(cString: strerror(code)))."]
    )
}

private func automaticMode(_ display: DisplayController, usePreferredExecutable: Bool) throws -> Never {
    let current = ExecutableLocator.current()
    if usePreferredExecutable {
        do {
            let preferred = try AgentManager.prepareAutomaticExecutable(fallback: current)
            if preferred.path != current.path {
                try execAutomaticMode(preferred)
            }
        } catch {
            fputs("Agent update fallback: \(error.localizedDescription)\n", stderr)
        }
    }
    try AutoController(
        display: display,
        executableURL: current,
        runningVersion: version
    ).run()
}

private func suspendAndRestore(_ display: DisplayController, reason: String) throws {
    try BuiltinCtlPaths.suspend(reason: reason)
    try enableAndClearRecovery(display)
}

private func enableAndClearRecovery(_ display: DisplayController) throws {
    try display.setBuiltinEnabled(true)
    try BuiltinCtlPaths.clearBuiltinDisabledMarker()
}

private func disableWithRecoveryMarker(
    _ display: DisplayController,
    requireAutomationAllowed: Bool = false
) throws {
    try BuiltinCtlPaths.markBuiltinDisabled()
    do {
        try display.setBuiltinEnabled(false, requireAutomationAllowed: requireAutomationAllowed)
    } catch {
        // CGComplete may report an error after partially changing topology.
        // Always attempt fail-open restoration; retain the marker if it fails.
        try? enableAndClearRecovery(display)
        throw error
    }
}

private func testOff(_ display: DisplayController) throws {
    try disableWithRecoveryMarker(display)
    var keepDisabled = false
    var restored = false
    defer {
        if !keepDisabled && !restored { try? enableAndClearRecovery(display) }
    }

    print("Built-in display disabled for testing.")
    print("Type KEEP and press Return within 15 seconds to keep it disabled; otherwise it will be restored.")
    fflush(stdout)
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let result = poll(&descriptor, 1, 15_000)
    if result > 0, readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "KEEP" {
        keepDisabled = true
        print("Built-in display remains disabled.")
    } else {
        try enableAndClearRecovery(display)
        restored = true
        print("Built-in display restored.")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 else { usage(); exit(64) }
let command = arguments[0]
let display = DisplayController()

do {
    switch command {
    case "status": try status(display)
    case "on":
        try enableAndClearRecovery(display)
        print("Built-in display enabled.")
    case "off":
        try disableWithRecoveryMarker(display)
        print("Built-in display disabled.")
    case "auto": try automaticMode(display, usePreferredExecutable: false)
    case "suspend", "recover":
        try suspendAndRestore(display, reason: command == "recover" ? "recovery" : "user")
        print("Automatic built-in display switching suspended.")
        print("Built-in display enabled.")
    case "resume":
        if BuiltinCtlPaths.hasDisabledState {
            try enableAndClearRecovery(display)
        }
        // Write before removing the kill switch. A running daemon consumes only
        // requests newer than its own start; a future daemon ignores this as stale.
        try BuiltinCtlPaths.requestRearm()
        if FileManager.default.fileExists(atPath: BuiltinCtlPaths.disabled.path) {
            try FileManager.default.removeItem(at: BuiltinCtlPaths.disabled)
        }
        print("Automatic built-in display switching resumed.")
        if daemonState().running {
            print("Running automation explicitly re-armed; startup grace and reconnect latch will be cleared.")
        } else {
            print("No automation process is running; its next start will retain the startup safety window.")
        }
    case "watch": try watch(display)
    case "test-off": try testOff(display)
    case "install-agent":
        try suspendAndRestore(display, reason: "installed-suspended")
        try AgentManager().install(executable: ExecutableLocator.current())
        print("LaunchAgent installed and started in suspended mode.")
        print("Run '\(AgentManager.installedExecutable.path) resume' when you are ready to enable automatic switching.")
    case "restart-agent":
        let manager = AgentManager()
        guard manager.isInstalled else {
            throw AgentManagerError.command("LaunchAgent is not installed; run 'builtinctl install-agent' first.")
        }
        let wasSuspended = BuiltinCtlPaths.isSuspended
        try suspendAndRestore(display, reason: "agent-restart")
        try manager.install(executable: ExecutableLocator.current())
        if !wasSuspended {
            try BuiltinCtlPaths.requestRearm()
            if FileManager.default.fileExists(atPath: BuiltinCtlPaths.disabled.path) {
                try FileManager.default.removeItem(at: BuiltinCtlPaths.disabled)
            }
        }
        print("LaunchAgent updated and restarted with builtinctl \(version).")
        print(wasSuspended ? "Automation remains suspended." : "Automation state restored and explicitly re-armed.")
    case "uninstall-agent":
        try suspendAndRestore(display, reason: "uninstalled")
        try AgentManager().uninstall()
        print("LaunchAgent and installed binary removed. Automation remains suspended.")
    case "purge":
        try suspendAndRestore(display, reason: "purged")
        try AgentManager().purge()
        print("Built-in display enabled.")
        print("LaunchAgent, copied binary, configuration, and logs removed.")
        print("The package-manager CLI remains installed; remove it separately if desired.")
    case "_auto-on": try enableAndClearRecovery(display)
    case "_auto-off": try disableWithRecoveryMarker(display, requireAutomationAllowed: true)
    case "_launch-auto": try automaticMode(display, usePreferredExecutable: true)
    case "--version", "version": print("builtinctl \(version)")
    default: usage(); exit(64)
    }
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
