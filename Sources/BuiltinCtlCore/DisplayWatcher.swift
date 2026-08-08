import CoreGraphics
import Foundation

private func displayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    Unmanaged<DisplayWatcher>.fromOpaque(context).takeUnretainedValue().receive(display, flags: flags)
}

public final class DisplayWatcher {
    public typealias Handler = (CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void
    private let handler: Handler
    private var registered = false

    public init(handler: @escaping Handler) { self.handler = handler }

    public func start() throws {
        guard !registered else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let error = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)
        guard error == .success else { throw DisplayError.configuration(error) }
        registered = true
    }

    public func stop() {
        guard registered else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, context)
        registered = false
    }

    fileprivate func receive(_ display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        handler(display, flags)
    }

    deinit { stop() }
}
