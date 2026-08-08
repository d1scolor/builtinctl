import BuiltinCtlCore
import CoreGraphics
import Darwin
import Dispatch
import Foundation

private let version = "0.1.0"

private func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

private func daemonState() -> (running: Bool, safeMode: Bool) {
    guard let text = try? String(contentsOf: BuiltinCtlPaths.pid),
          let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          kill(pid, 0) == 0 else { return (false, false) }
    let safeUntil = (try? String(contentsOf: BuiltinCtlPaths.safeUntil))
        .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return (true, safeUntil.map { Date().timeIntervalSince1970 < $0 } ?? false)
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
    print("  Daemon:        \(daemon.running ? "running" : "stopped")")
    print("  Safe mode:     \(yesNo(daemon.safeMode))\n")
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
    print("Usage: builtinctl <status|on|off|auto|suspend|recover|resume|watch|test-off|install-agent|uninstall-agent>")
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

private func currentExecutableURL() -> URL {
    URL(
        fileURLWithPath: CommandLine.arguments[0],
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ).standardizedFileURL
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
    case "auto": try AutoController(display: display).run()
    case "suspend", "recover":
        try suspendAndRestore(display, reason: command == "recover" ? "recovery" : "user")
        print("Automatic built-in display switching suspended.")
        print("Built-in display enabled.")
    case "resume":
        if BuiltinCtlPaths.hasDisabledState {
            try enableAndClearRecovery(display)
        }
        if FileManager.default.fileExists(atPath: BuiltinCtlPaths.disabled.path) {
            try FileManager.default.removeItem(at: BuiltinCtlPaths.disabled)
        }
        print("Automatic built-in display switching resumed.")
    case "watch": try watch(display)
    case "test-off": try testOff(display)
    case "install-agent":
        try suspendAndRestore(display, reason: "installed-suspended")
        try AgentManager().install(executable: currentExecutableURL())
        print("LaunchAgent installed and started in suspended mode.")
        print("Run '\(AgentManager.installedExecutable.path) resume' when you are ready to enable automatic switching.")
    case "uninstall-agent":
        try suspendAndRestore(display, reason: "uninstalled")
        try AgentManager().uninstall()
        print("LaunchAgent and installed binary removed. Automation remains suspended.")
    case "_auto-on": try enableAndClearRecovery(display)
    case "_auto-off": try disableWithRecoveryMarker(display, requireAutomationAllowed: true)
    case "--version", "version": print("builtinctl \(version)")
    default: usage(); exit(64)
    }
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
