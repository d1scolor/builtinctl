import Dispatch
import Foundation
import IOKit
import IOKit.pwr_mgt

enum SystemPowerEvent: Equatable {
    case clamshellChanged(closed: Bool)
    case initialGraphicsAvailable
    case initialGraphicsUnavailable
    case sleepPending
    case sleepCancelled
    case poweringOn
    case systemDidWake
    case graphicsUnavailable
    case graphicsAvailable
}

// IOMessage.h builds these values with C macros that Swift cannot import.
// They are public IOKit messages delivered by IORegisterForSystemPower.
private enum SystemPowerMessage {
    static let canSleep: UInt32 = 0xe000_0270
    static let willSleep: UInt32 = 0xe000_0280
    static let willNotSleep: UInt32 = 0xe000_0290
    static let hasPoweredOn: UInt32 = 0xe000_0300
    static let willPowerOn: UInt32 = 0xe000_0320
    static let capabilityChange: UInt32 = 0xe000_0340
}

func systemPowerEvent(for messageType: UInt32) -> SystemPowerEvent? {
    switch messageType {
    case SystemPowerMessage.canSleep, SystemPowerMessage.willSleep:
        return .sleepPending
    case SystemPowerMessage.willNotSleep:
        return .sleepCancelled
    case SystemPowerMessage.willPowerOn:
        return .poweringOn
    case SystemPowerMessage.hasPoweredOn:
        return .systemDidWake
    default:
        return nil
    }
}

func systemCapabilityEvent(
    changeFlags: UInt32,
    fromCapabilities: UInt32,
    toCapabilities: UInt32
) -> SystemPowerEvent? {
    let graphics = UInt32(kIOPMSystemCapabilityGraphics)
    let hadGraphics = fromCapabilities & graphics != 0
    let willHaveGraphics = toCapabilities & graphics != 0
    let transitionFlags = UInt32(kIOPMSystemCapabilityWillChange)
        | UInt32(kIOPMSystemCapabilityDidChange)
    if changeFlags & transitionFlags == 0 {
        return willHaveGraphics ? .initialGraphicsAvailable : .initialGraphicsUnavailable
    }
    guard hadGraphics != willHaveGraphics else { return nil }

    if !willHaveGraphics {
        return .graphicsUnavailable
    }
    return changeFlags & UInt32(kIOPMSystemCapabilityDidChange) != 0
        ? .graphicsAvailable
        : .poweringOn
}

func systemPowerMessageRequiresAcknowledgement(_ messageType: UInt32) -> Bool {
    messageType == SystemPowerMessage.canSleep || messageType == SystemPowerMessage.willSleep
}

enum SystemPowerWatcherError: LocalizedError {
    case registrationFailed

    var errorDescription: String? {
        "Could not register for macOS system power notifications."
    }
}

final class SystemPowerWatcher {
    private let handler: (SystemPowerEvent) -> Void
    private var connection: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var capabilityPort: IONotificationPortRef?
    private var capabilityNotifier: io_object_t = 0
    private var clamshellNotifier: io_object_t = 0
    private var rootPowerService: io_service_t = 0
    private var lastClamshellClosed: Bool?

    init(handler: @escaping (SystemPowerEvent) -> Void) {
        self.handler = handler
    }

    func start() throws {
        guard connection == 0 else { return }
        var port: IONotificationPortRef?
        var registeredNotifier: io_object_t = 0
        let registeredConnection = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &port,
            { reference, _, messageType, messageArgument in
                guard let reference else { return }
                Unmanaged<SystemPowerWatcher>
                    .fromOpaque(reference)
                    .takeUnretainedValue()
                    .receive(messageType: messageType, argument: messageArgument)
            },
            &registeredNotifier
        )
        guard registeredConnection != 0, let port else {
            throw SystemPowerWatcherError.registrationFailed
        }

        connection = registeredConnection
        notificationPort = port
        notifier = registeredNotifier
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        do {
            try startCapabilityMonitoring()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        guard connection != 0 else { return }
        if let notificationPort {
            IONotificationPortSetDispatchQueue(notificationPort, nil)
        }
        if let capabilityPort {
            IONotificationPortSetDispatchQueue(capabilityPort, nil)
        }
        _ = IODeregisterForSystemPower(&notifier)
        if capabilityNotifier != 0 {
            IOObjectRelease(capabilityNotifier)
        }
        if clamshellNotifier != 0 {
            IOObjectRelease(clamshellNotifier)
        }
        if let capabilityPort {
            IONotificationPortDestroy(capabilityPort)
        }
        if rootPowerService != 0 {
            IOObjectRelease(rootPowerService)
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
        IOServiceClose(connection)
        connection = 0
        notifier = 0
        notificationPort = nil
        capabilityNotifier = 0
        clamshellNotifier = 0
        capabilityPort = nil
        rootPowerService = 0
        lastClamshellClosed = nil
    }

    private func receive(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        // Acknowledge before doing any work so builtinctl can never delay sleep.
        if systemPowerMessageRequiresAcknowledgement(messageType) {
            _ = IOAllowPowerChange(connection, Int(bitPattern: argument))
        }
        if let event = systemPowerEvent(for: messageType) {
            handler(event)
        }
    }

    private func startCapabilityMonitoring() throws {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            if service != 0 { IOObjectRelease(service) }
            throw SystemPowerWatcherError.registrationFailed
        }

        var registeredNotifier: io_object_t = 0
        let result = "IOPriorityPowerStateInterest".withCString { interest in
            IOServiceAddInterestNotification(
                port,
                service,
                interest,
                { reference, _, messageType, messageArgument in
                    guard let reference,
                          messageType == SystemPowerMessage.capabilityChange,
                          let messageArgument else { return }
                    let parameters = messageArgument
                        .assumingMemoryBound(to: IOPMSystemCapabilityChangeParameters.self)
                        .pointee
                    Unmanaged<SystemPowerWatcher>
                        .fromOpaque(reference)
                        .takeUnretainedValue()
                        .receiveCapabilityChange(parameters)
                },
                Unmanaged.passUnretained(self).toOpaque(),
                &registeredNotifier
            )
        }
        guard result == kIOReturnSuccess else {
            IONotificationPortDestroy(port)
            IOObjectRelease(service)
            throw SystemPowerWatcherError.registrationFailed
        }

        var registeredClamshellNotifier: io_object_t = 0
        let clamshellResult = kIOGeneralInterest.withCString { interest in
            IOServiceAddInterestNotification(
                port,
                service,
                interest,
                { reference, _, messageType, messageArgument in
                    guard let reference,
                          let closed = clamshellClosed(
                            messageType: messageType,
                            messageArgument: messageArgument
                          ) else { return }
                    Unmanaged<SystemPowerWatcher>
                        .fromOpaque(reference)
                        .takeUnretainedValue()
                        .receiveClamshellState(closed)
                },
                Unmanaged.passUnretained(self).toOpaque(),
                &registeredClamshellNotifier
            )
        }
        guard clamshellResult == kIOReturnSuccess else {
            if registeredNotifier != 0 { IOObjectRelease(registeredNotifier) }
            if registeredClamshellNotifier != 0 {
                IOObjectRelease(registeredClamshellNotifier)
            }
            IONotificationPortDestroy(port)
            IOObjectRelease(service)
            throw SystemPowerWatcherError.registrationFailed
        }

        rootPowerService = service
        capabilityPort = port
        capabilityNotifier = registeredNotifier
        clamshellNotifier = registeredClamshellNotifier
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        receiveClamshellState(from: service)
    }

    private func receiveCapabilityChange(
        _ parameters: IOPMSystemCapabilityChangeParameters
    ) {
        if let event = systemCapabilityEvent(
            changeFlags: parameters.changeFlags,
            fromCapabilities: parameters.fromCapabilities,
            toCapabilities: parameters.toCapabilities
        ) {
            handler(event)
        }
    }

    private func receiveClamshellState(from service: io_service_t) {
        guard let closed = ClamshellState.read(from: service) else { return }
        receiveClamshellState(closed)
    }

    private func receiveClamshellState(_ closed: Bool) {
        guard closed != lastClamshellClosed else { return }
        lastClamshellClosed = closed
        handler(.clamshellChanged(closed: closed))
    }

    deinit {
        stop()
    }
}
