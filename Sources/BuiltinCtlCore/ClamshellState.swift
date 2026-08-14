import Foundation
import IOKit
import IOKit.pwr_mgt

public enum ClamshellState {
    public static func current() -> Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return read(from: service)
    }

    static func read(from service: io_service_t) -> Bool? {
        guard service != 0,
              let value = IORegistryEntryCreateCFProperty(
                  service,
                  kAppleClamshellStateKey as CFString,
                  kCFAllocatorDefault,
                  0
              )?.takeRetainedValue() else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    public static func requireOpen() throws {
        if current() == true { throw DisplayError.clamshellClosed }
    }
}

// Swift cannot import the structured iokit_family_msg(...) C macro. This is the
// public kIOPMMessageClamshellStateChange value from IOPM.h.
let clamshellStateChangeMessage: UInt32 = 0xe003_4100

func clamshellClosed(
    messageType: UInt32,
    messageArgument: UnsafeMutableRawPointer?
) -> Bool? {
    guard messageType == clamshellStateChangeMessage else { return nil }
    let bits = messageArgument.map { UInt(bitPattern: $0) } ?? 0
    return bits & UInt(kClamshellStateBit) != 0
}
