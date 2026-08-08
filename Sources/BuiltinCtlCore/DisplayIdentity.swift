import CoreGraphics

enum DisplayIdentity {
    // ASCII "unkn" and "virt". macOS 26 exposes this synthetic active display
    // after the last physical external is removed while the panel is disabled.
    static let unplugPlaceholderVendor: UInt32 = 0x756e6b6e
    static let unplugPlaceholderModel: UInt32 = 0x76697274

    static func isUnplugPlaceholder(vendor: UInt32, model: UInt32) -> Bool {
        vendor == unplugPlaceholderVendor && model == unplugPlaceholderModel
    }

    static func isUnplugPlaceholder(_ display: CGDirectDisplayID) -> Bool {
        isUnplugPlaceholder(
            vendor: CGDisplayVendorNumber(display),
            model: CGDisplayModelNumber(display)
        )
    }
}
