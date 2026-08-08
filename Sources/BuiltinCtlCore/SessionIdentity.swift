import Darwin
import Foundation

struct SystemSessionIdentity: Codable, Equatable {
    let bootTimeSeconds: Int64
    let bootTimeMicroseconds: Int32
    let auditSessionID: Int32

    static func current() throws -> SystemSessionIdentity {
        var bootTime = timeval()
        var bootTimeSize = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, u_int(mib.count), &bootTime, &bootTimeSize, nil, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var auditInfo = auditinfo_addr()
        guard getaudit_addr(&auditInfo, Int32(MemoryLayout<auditinfo_addr>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        return SystemSessionIdentity(
            bootTimeSeconds: Int64(bootTime.tv_sec),
            bootTimeMicroseconds: Int32(bootTime.tv_usec),
            auditSessionID: Int32(auditInfo.ai_asid)
        )
    }
}

struct DisabledStateMarker: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let identity: SystemSessionIdentity?

    init(identity: SystemSessionIdentity?) {
        self.version = Self.currentVersion
        self.identity = identity
    }
}

struct CrashSuspensionMarker: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let reason: String
    let identity: SystemSessionIdentity?

    init(identity: SystemSessionIdentity?) {
        self.version = Self.currentVersion
        self.reason = "unclean-exit"
        self.identity = identity
    }
}

enum DisabledStateOrigin: Equatable {
    case sameSession
    case priorSession
    case unknown
}

func disabledStateOrigin(
    markerData: Data,
    currentIdentity: SystemSessionIdentity?
) -> DisabledStateOrigin {
    guard let currentIdentity,
          let marker = try? JSONDecoder().decode(DisabledStateMarker.self, from: markerData),
          marker.version == DisabledStateMarker.currentVersion,
          let markerIdentity = marker.identity else {
        return .unknown
    }
    return markerIdentity == currentIdentity ? .sameSession : .priorSession
}

func crashSuspensionOrigin(
    markerData: Data,
    currentIdentity: SystemSessionIdentity?
) -> DisabledStateOrigin? {
    if String(data: markerData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) == "unclean-exit" {
        return .unknown
    }
    guard let marker = try? JSONDecoder().decode(CrashSuspensionMarker.self, from: markerData),
          marker.version == CrashSuspensionMarker.currentVersion,
          marker.reason == "unclean-exit" else {
        return nil
    }
    guard let currentIdentity, let markerIdentity = marker.identity else { return .unknown }
    return markerIdentity == currentIdentity ? .sameSession : .priorSession
}
