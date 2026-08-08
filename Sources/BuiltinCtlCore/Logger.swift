import Foundation
import Darwin

public struct Logger {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public init() {}

    public func log(_ message: String) {
        print("\(Self.formatter.string(from: Date())) \(message)")
        fflush(stdout)
    }
}
