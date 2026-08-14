import AppKit
import CoreGraphics
import Darwin
import Dispatch
import Foundation

public final class AutoController {
    public static let startupGrace: TimeInterval = 60
    private let display: DisplayController
    private let logger: Logger
    private let executableURL: URL
    private let runningVersion: String
    private let startedAt = Date()
    private var disableAllowedAt: Date
    private var watcher: DisplayWatcher?
    private var pending: DispatchWorkItem?
    private var watchdog: DispatchSourceTimer?
    private var powerWatcher: SystemPowerWatcher?
    private var signals: [DispatchSourceSignal] = []
    private var lastSummary: String?
    private var waitingForExternalReconnect = false
    private var disablingExternalIDs: Set<CGDirectDisplayID> = []
    private var stopping = false
    private var systemSleepPending = false
    private var graphicsUnavailable = false
    private var lidClosed: Bool
    private var lidSettleUntil: Date?
    private var processLock: ProcessLock?
    private var workspaceObservers: [NSObjectProtocol] = []

    public init(
        display: DisplayController = DisplayController(),
        logger: Logger = Logger(),
        executableURL: URL? = nil,
        runningVersion: String = "development"
    ) {
        self.display = display
        self.logger = logger
        self.disableAllowedAt = Date().addingTimeInterval(Self.startupGrace)
        self.executableURL = executableURL ?? ExecutableLocator.current()
        self.runningVersion = runningVersion
        self.lidClosed = ClamshellState.current() ?? false
    }

    public func run() throws -> Never {
        try BuiltinCtlPaths.ensureDirectory()
        processLock = try ProcessLock(url: BuiltinCtlPaths.lock, purpose: "automatic-mode process")
        try BuiltinCtlPaths.writeAtomically("\(getpid())\n", to: BuiltinCtlPaths.pid)
        try BuiltinCtlPaths.writeAtomically("\(startedAt.timeIntervalSince1970)\n", to: BuiltinCtlPaths.started)
        try BuiltinCtlPaths.writeAtomically("\(disableAllowedAt.timeIntervalSince1970)\n", to: BuiltinCtlPaths.safeUntil)
        try BuiltinCtlPaths.writeAtomically("\(runningVersion)\n", to: BuiltinCtlPaths.agentVersion)
        try? BuiltinCtlPaths.clearRecoveryLatch()

        logger.log("builtinctl starting")
        var startupGraceActive = true
        let currentIdentity = try? SystemSessionIdentity.current()
        if BuiltinCtlPaths.hasDisabledState {
            let markerOrigin = BuiltinCtlPaths.disabledStateOrigin(
                currentIdentity: currentIdentity
            )
            switch markerOrigin {
            case .priorSession:
                logger.log("disabled state from a prior boot or login found; restoring built-in")
                if lidClosed {
                    logger.log("lid closed; prior-session recovery deferred until lid opens")
                    break
                }
                do {
                    try restoreBuiltin()
                    _ = try BuiltinCtlPaths.clearPriorCrashSuspension(
                        currentIdentity: currentIdentity
                    )
                    logger.log("prior-session recovery complete; retaining 60s startup grace")
                } catch {
                    if !deferMutationIfLidClosed(error, context: "prior-session recovery") {
                        try? BuiltinCtlPaths.suspend(reason: "startup-recovery-failed")
                        logger.log("prior-session recovery failed; automation suspended: \(error.localizedDescription)")
                        throw error
                    }
                }
            case .sameSession, .unknown:
                logger.log(markerOrigin == .sameSession
                    ? "same-session unclean disabled state found; restoring and suspending automation"
                    : "unrecognized disabled state found; restoring and suspending automation")
                var suspensionError: Error?
                if !BuiltinCtlPaths.isSuspended {
                    do {
                        try BuiltinCtlPaths.suspendForUncleanExit(identity: currentIdentity)
                    } catch {
                        suspensionError = error
                        logger.log("could not persist crash suspension; restoring before exit: \(error.localizedDescription)")
                    }
                }
                if lidClosed {
                    if let suspensionError { throw suspensionError }
                    try deactivateStartupGrace()
                    startupGraceActive = false
                    logger.log("lid closed; crash recovery deferred until lid opens")
                    break
                }
                do {
                    try restoreBuiltin()
                } catch {
                    if deferMutationIfLidClosed(error, context: "crash recovery") {
                        if let suspensionError { throw suspensionError }
                        try deactivateStartupGrace()
                        startupGraceActive = false
                        break
                    }
                    logger.log("crash recovery failed: \(error.localizedDescription)")
                    throw error
                }
                if let suspensionError {
                    logger.log("crash recovery restored built-in, but automation cannot remain safely suspended")
                    throw suspensionError
                }
                try deactivateStartupGrace()
                startupGraceActive = false
                logger.log("crash recovery restored built-in; automation requires explicit resume")
            }
        } else {
            var startupRestored = false
            if lidClosed {
                logger.log("lid closed; startup display restore deferred until lid opens")
            } else {
                do {
                    try restoreBuiltin()
                    startupRestored = true
                } catch {
                    if !deferMutationIfLidClosed(error, context: "startup display restore") {
                        logger.log("startup restore failed; automation suspended: \(error.localizedDescription)")
                        try BuiltinCtlPaths.suspend(reason: "startup-restore-failed")
                    }
                }
            }
            if (startupRestored || lidClosed),
               let crashOrigin = BuiltinCtlPaths.crashSuspensionOrigin(
                currentIdentity: currentIdentity
            ) {
                do {
                    if crashOrigin == .priorSession {
                        _ = try BuiltinCtlPaths.clearPriorCrashSuspension(
                            currentIdentity: currentIdentity
                        )
                        logger.log("prior-session crash suspension cleared; retaining 60s startup grace")
                    } else {
                        startupGraceActive = false
                        try deactivateStartupGrace()
                        logger.log("same-session or unrecognized crash suspension retained; explicit resume required")
                    }
                } catch {
                    logger.log("crash suspension update warning: \(error.localizedDescription)")
                }
            }
        }
        logger.log(startupGraceActive
            ? "entering 60s startup grace"
            : "startup grace inactive while automation is suspended")

        watcher = DisplayWatcher { [weak self] _, flags in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.logger.log("display reconfiguration flags=\(flags.rawValue)")
                self.schedule(flags.contains(.removeFlag) ? 0.075 : 0.2)
            }
        }
        try watcher?.start()
        installSystemPowerWatcher()
        installSignalHandlers()
        installWorkspaceObservers()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        // The timer deliberately retains the controller for the lifetime of auto mode.
        // `run()` never returns, and all other asynchronous handlers may otherwise be
        // weak references to a temporary AutoController created by the CLI.
        timer.setEventHandler { [self] in evaluate() }
        timer.resume()
        watchdog = timer

        dispatchMain()
    }

    private func schedule(_ delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func deactivateStartupGrace() throws {
        disableAllowedAt = Date()
        try BuiltinCtlPaths.writeAtomically(
            "\(disableAllowedAt.timeIntervalSince1970)\n",
            to: BuiltinCtlPaths.safeUntil
        )
    }

    /// A lid close can race a topology snapshot or helper launch. Treat that as a
    /// normal clamshell transition, not as a failed recovery that suspends auto mode.
    @discardableResult
    private func deferMutationIfLidClosed(_ error: Error, context: String) -> Bool {
        let explicitClamshellError: Bool
        if let displayError = error as? DisplayError,
           case .clamshellClosed = displayError {
            explicitClamshellError = true
        } else {
            explicitClamshellError = false
        }
        guard explicitClamshellError || ClamshellState.current() == true else {
            return false
        }
        lidClosed = true
        lidSettleUntil = nil
        pending?.cancel()
        lastSummary = nil
        logger.log("lid closed during \(context); display mutation deferred")
        return true
    }

    private func evaluate() {
        guard !stopping else { return }
        applyExplicitRearmIfRequested()
        if let currentLidState = ClamshellState.current(), currentLidState != lidClosed {
            handleClamshellChange(closed: currentLidState)
        }
        if systemSleepPending || graphicsUnavailable {
            let summary = "power-transition=true graphics-unavailable=\(graphicsUnavailable) automation-paused=true"
            if summary != lastSummary { logger.log(summary); lastSummary = summary }
            return
        }
        if lidClosed {
            let summary = "lid-closed=true automation-paused=true"
            if summary != lastSummary { logger.log(summary); lastSummary = summary }
            return
        }
        if let lidSettleUntil, Date() < lidSettleUntil {
            let summary = "lid-settling=true automation-paused=true"
            if summary != lastSummary { logger.log(summary); lastSummary = summary }
            return
        }
        lidSettleUntil = nil
        do {
            let snapshot = try display.snapshot()
            let armed = Date() >= disableAllowedAt
            let suspended = BuiltinCtlPaths.isSuspended
            let activeExternalIDs = Set(snapshot.activeExternals)
            let sleepingExternalIDs = Set(snapshot.sleepingExternals)
            if shouldPauseForSleepingExternal(
                activeExternalIDs: activeExternalIDs,
                trackedExternalIDs: disablingExternalIDs,
                sleepingExternalIDs: sleepingExternalIDs
            ) {
                let summary = "builtin=\(snapshot.builtinActive) externals=0 source=cg external-sleep=true automation-paused=true"
                if summary != lastSummary { logger.log(summary); lastSummary = summary }
                return
            }
            let trackedExternalRemains = disablingExternalIDs.isEmpty
                || !disablingExternalIDs.isDisjoint(with: activeExternalIDs)
            let externalCount = trackedExternalRemains ? activeExternalIDs.count : 0
            let topologyValid = true

            // After any automatic restoration, observe a truly external-free state
            // before allowing another disable. This prevents an uncertain detector
            // from producing an enable/disable loop.
            if waitingForExternalReconnect && snapshot.builtinActive {
                if snapshot.activeExternals.isEmpty {
                    setRecoveryLatched(false)
                    logger.log("external removal confirmed; automation ready for reconnect")
                } else {
                    let summary = "builtin=true externals=\(snapshot.activeExternals.count) source=cg recovery-latched=true armed=\(armed) suspended=\(suspended)"
                    if summary != lastSummary { logger.log(summary); lastSummary = summary }
                    return
                }
            }
            let state = TopologyState(
                builtinFound: snapshot.builtin != nil,
                builtinActive: snapshot.builtinActive,
                activeExternalCount: externalCount,
                automationArmed: armed,
                suspended: suspended,
                topologyValid: topologyValid,
                lidClosed: lidClosed
            )
            let summary = "builtin=\(state.builtinActive) externals=\(state.activeExternalCount) source=cg valid=\(topologyValid) armed=\(armed) suspended=\(suspended)"
            if summary != lastSummary { logger.log(summary); lastSummary = summary }

            let desired = desiredState(for: state)
            if desired == .disabled && state.builtinActive {
                disablingExternalIDs = activeExternalIDs
                try BuiltinCtlPaths.markBuiltinDisabled()
                try mutateBuiltin(enabled: false)
                logger.log("built-in disabled id=\(snapshot.builtin!)")
            } else if desired == .enabled && !state.builtinActive && state.builtinFound {
                try restoreBuiltin()
                setRecoveryLatched(true)
                logger.log("built-in enabled id=\(snapshot.builtin!)")
            } else if desired == .enabled && state.builtinActive && BuiltinCtlPaths.hasDisabledState {
                try BuiltinCtlPaths.clearBuiltinDisabledMarker()
                disablingExternalIDs.removeAll()
            }
        } catch {
            if deferMutationIfLidClosed(error, context: "topology evaluation") {
                return
            }
            logger.log("evaluation error: \(error.localizedDescription)")
            do {
                try restoreBuiltin()
                setRecoveryLatched(true)
            } catch {
                if !deferMutationIfLidClosed(error, context: "fail-open recovery") {
                    logger.log("fail-open restore warning: \(error.localizedDescription)")
                }
            }
        }
    }

    private func applyExplicitRearmIfRequested() {
        do {
            guard try BuiltinCtlPaths.consumeRearmRequest(startedAt: startedAt) else { return }
            disableAllowedAt = Date()
            try BuiltinCtlPaths.writeAtomically(
                "\(disableAllowedAt.timeIntervalSince1970)\n",
                to: BuiltinCtlPaths.safeUntil
            )
            setRecoveryLatched(false)
            lastSummary = nil
            logger.log("explicit resume received; startup grace and recovery latch cleared")
        } catch {
            logger.log("resume request warning: \(error.localizedDescription)")
        }
    }

    private func setRecoveryLatched(_ latched: Bool) {
        waitingForExternalReconnect = latched
        do {
            if latched {
                try BuiltinCtlPaths.markRecoveryLatched()
            } else {
                try BuiltinCtlPaths.clearRecoveryLatch()
            }
        } catch {
            logger.log("recovery latch state warning: \(error.localizedDescription)")
        }
    }

    /// Keep the event loop isolated from private API failures. The helper repeats
    /// topology and kill-switch validation under a cross-process mutation lock.
    private func mutateBuiltin(enabled: Bool) throws {
        try runHelper(enabled ? "_auto-on" : "_auto-off")
    }

    private func runHelper(_ command: String, timeout: TimeInterval = 5) throws {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = [command]
        process.standardOutput = output
        process.standardError = errors
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        if completed.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            throw NSError(
                domain: "builtinctl.helper",
                code: Int(ETIMEDOUT),
                userInfo: [NSLocalizedDescriptionKey: "display helper timed out"]
            )
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "builtinctl.helper",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail?.isEmpty == false ? detail! : "display helper failed"]
            )
        }
    }

    private func restoreBuiltin() throws {
        do {
            try mutateBuiltin(enabled: true)
        } catch {
            // Enabling is fail-open. If spawning the isolated helper fails, use the
            // already-running controller as an independent recovery path.
            try display.setBuiltinEnabled(true)
        }
        let restored = try display.snapshot()
        guard restored.builtin != nil, restored.builtinActive else {
            throw DisplayError.postcondition("built-in display was not restored.")
        }
        try BuiltinCtlPaths.clearBuiltinDisabledMarker()
        disablingExternalIDs.removeAll()
    }

    private func installSignalHandlers() {
        for number in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.stop(signal: number) }
            source.resume()
            signals.append(source)
        }
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake(reason: "system wake")
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDisplaysSleep()
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake(reason: "display wake")
        })
    }

    private func installSystemPowerWatcher() {
        let watcher = SystemPowerWatcher { [weak self] event in
            self?.handleSystemPowerEvent(event)
        }
        do {
            try watcher.start()
            powerWatcher = watcher
            logger.log("IOKit system power monitoring active")
        } catch {
            logger.log("IOKit system power monitoring unavailable: \(error.localizedDescription)")
        }
    }

    private func handleSystemPowerEvent(_ event: SystemPowerEvent) {
        guard !stopping else { return }
        switch event {
        case .clamshellChanged(let closed):
            handleClamshellChange(closed: closed)
        case .initialGraphicsAvailable:
            graphicsUnavailable = false
            lastSummary = nil
            logger.log("initial graphics capability available")
        case .initialGraphicsUnavailable:
            graphicsUnavailable = true
            lastSummary = nil
            logger.log("initial graphics capability unavailable; automation paused")
        case .sleepPending:
            pending?.cancel()
            if !systemSleepPending {
                logger.log("system sleep pending; automation paused")
            }
            systemSleepPending = true
            lastSummary = nil
        case .sleepCancelled:
            let wasPending = systemSleepPending
            systemSleepPending = false
            lastSummary = nil
            if wasPending {
                logger.log("system sleep cancelled; automation resumed")
                schedule(0.2)
            }
        case .poweringOn:
            guard systemSleepPending || graphicsUnavailable else {
                logger.log("power-on transition ignored without preceding sleep")
                return
            }
            systemSleepPending = true
            lastSummary = nil
            logger.log("system power-on started; waiting for hardware")
        case .systemDidWake:
            systemSleepPending = false
            lastSummary = nil
            if graphicsUnavailable {
                logger.log("system woke without graphics; automation remains paused")
            } else {
                schedule(0.2)
            }
        case .graphicsUnavailable:
            pending?.cancel()
            if !graphicsUnavailable {
                logger.log("graphics capability unavailable; automation paused")
            }
            graphicsUnavailable = true
            lastSummary = nil
        case .graphicsAvailable:
            graphicsUnavailable = false
            systemSleepPending = false
            lastSummary = nil
            if lidClosed {
                logger.log("IOKit graphics wake while lid closed; restoration deferred")
            } else {
                handleWake(reason: "IOKit graphics wake")
            }
        }
    }

    private func handleClamshellChange(closed: Bool) {
        guard closed != lidClosed else { return }
        lidClosed = closed
        pending?.cancel()
        lastSummary = nil
        if closed {
            lidSettleUntil = nil
            logger.log("lid closed; display automation paused")
            return
        }

        let settleUntil = Date().addingTimeInterval(3)
        lidSettleUntil = settleUntil
        if disableAllowedAt < settleUntil {
            disableAllowedAt = settleUntil
            try? BuiltinCtlPaths.writeAtomically(
                "\(disableAllowedAt.timeIntervalSince1970)\n",
                to: BuiltinCtlPaths.safeUntil
            )
        }
        logger.log("lid opened; reevaluating displays after 3s settle window")
        schedule(3)
    }

    private func handleDisplaysSleep() {
        guard !stopping else { return }
        pending?.cancel()
        lastSummary = nil
        logger.log("display-sleep notification received; polling will verify topology")
    }

    private func handleWake(reason: String) {
        guard !stopping else { return }
        if lidClosed || ClamshellState.current() == true {
            lidClosed = true
            lastSummary = nil
            logger.log("\(reason) while lid closed; restoration deferred")
            return
        }
        lastSummary = nil
        logger.log("\(reason); restoring built-in and entering 15s recovery window")
        disableAllowedAt = Date().addingTimeInterval(15)
        try? BuiltinCtlPaths.writeAtomically(
            "\(disableAllowedAt.timeIntervalSince1970)\n",
            to: BuiltinCtlPaths.safeUntil
        )
        do {
            try restoreBuiltin()
            setRecoveryLatched(false)
        } catch {
            if !deferMutationIfLidClosed(error, context: "wake recovery") {
                logger.log("wake restore failed; automation suspended: \(error.localizedDescription)")
                try? BuiltinCtlPaths.suspend(reason: "wake-restore-failed")
            }
        }
    }

    private func stop(signal number: Int32) -> Never {
        stopping = true
        pending?.cancel()
        watchdog?.cancel()
        watcher?.stop()
        powerWatcher?.stop()
        powerWatcher = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        var exitStatus: Int32 = 0
        if lidClosed || ClamshellState.current() == true {
            logger.log("lid closed; exit restore deferred to the next open-lid session")
        } else {
            do {
                try restoreBuiltin()
                logger.log("built-in restored on exit")
            } catch {
                if !deferMutationIfLidClosed(error, context: "exit recovery") {
                    exitStatus = 1
                    logger.log("exit restore warning: \(error.localizedDescription)")
                }
            }
        }
        try? FileManager.default.removeItem(at: BuiltinCtlPaths.pid)
        try? FileManager.default.removeItem(at: BuiltinCtlPaths.started)
        try? FileManager.default.removeItem(at: BuiltinCtlPaths.safeUntil)
        try? FileManager.default.removeItem(at: BuiltinCtlPaths.agentVersion)
        try? FileManager.default.removeItem(at: BuiltinCtlPaths.rearmRequest)
        try? BuiltinCtlPaths.clearRecoveryLatch()
        logger.log("stopping on signal \(number)")
        Darwin.exit(exitStatus)
    }
}
