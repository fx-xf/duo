import Foundation
import IOKit
import IOKit.hid

/// Reads the hinge angle straight off the Mac's own lid sensor.
///
/// Apple silicon MacBooks expose it as an HID device on the sensor usage page
/// (0x20) with usage 0x8A. Feature report 1 carries the angle as a little-endian
/// 16-bit value in degrees: 0 is shut, ~130 is a normally open lid.
final class LidAngleSensor {
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private var buffer = [UInt8](repeating: 0, count: 8)

    private static let usagePage = 0x20
    private static let usage = 0x8A
    private static let featureReportID: CFIndex = 1

    init?() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDPrimaryUsagePageKey: Self.usagePage,
            kIOHIDPrimaryUsageKey: Self.usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return nil
        }
        guard let device = Self.firstResponsiveDevice(in: manager) else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return nil
        }
        self.manager = manager
        self.device = device
    }

    deinit {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Current hinge angle in degrees, or nil if the sensor did not answer.
    func read() -> Double? {
        var length = buffer.count
        let result = buffer.withUnsafeMutableBufferPointer { ptr -> IOReturn in
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, Self.featureReportID, ptr.baseAddress!, &length)
        }
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        let degrees = Double(Int(buffer[1]) | (Int(buffer[2]) << 8))
        // The sensor reports a few degrees of slop past the mechanical stops.
        guard (0...360).contains(degrees) else { return nil }
        return degrees
    }

    private static func firstResponsiveDevice(in manager: IOHIDManager) -> IOHIDDevice? {
        guard let set = IOHIDManagerCopyDevices(manager) else { return nil }
        let count = CFSetGetCount(set)
        guard count > 0 else { return nil }
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(set, &values)

        for pointer in values.compactMap({ $0 }) {
            let device = Unmanaged<IOHIDDevice>.fromOpaque(pointer).takeUnretainedValue()
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            var probe = [UInt8](repeating: 0, count: 8)
            var length = probe.count
            let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, featureReportID, &probe, &length)
            if result == kIOReturnSuccess, length >= 3 {
                return device
            }
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        return nil
    }
}
