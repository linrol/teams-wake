import Foundation
import AppKit
import CoreGraphics
import IOKit

/// Hardware-level system idle time reset and keep-alive engine
public final class KeepAliveEngine {
    public static let shared = KeepAliveEngine()

    private init() {}

    /// Retrieve current macOS HIDIdleTime (in seconds) from IOHIDSystem registry
    public func getSystemIdleTime() -> Double {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOHIDSystem")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }

        var unmanagedDict: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanagedDict, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanagedDict?.takeRetainedValue() as? [String: Any],
              let nanoseconds = dict["HIDIdleTime"] as? Int64 else {
            return 0
        }
        return Double(nanoseconds) / 1_000_000_000.0
    }

    /// Perform a 1-pixel micro-movement to reset IOHIDSystem idle time and restore within 10ms
    /// Uses native CoreGraphics coordinates directly to ensure flawless multi-monitor / external display compatibility
    @discardableResult
    public func performMicroWiggle() -> Bool {
        // Direct CoreGraphics global physical coordinates (native multi-monitor support, zero offset drift)
        guard let currentLoc = CGEvent(source: nil)?.location else {
            return false
        }

        let pt1 = CGPoint(x: currentLoc.x + 1, y: currentLoc.y)
        let pt2 = currentLoc

        // 1. Move cursor 1 pixel and post mouse move event to HID event tap
        CGWarpMouseCursorPosition(pt1)
        if let ev1 = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt1, mouseButton: .left) {
            ev1.post(tap: .cghidEventTap)
        }

        // 2. Sleep 10ms
        usleep(10_000)

        // 3. Immediately restore cursor position to original physical point
        CGWarpMouseCursorPosition(pt2)
        if let ev2 = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt2, mouseButton: .left) {
            ev2.post(tap: .cghidEventTap)
        }

        return true
    }

    /// Check macOS Accessibility permission
    public func checkAccessibilityPermission(prompt: Bool = false) -> Bool {
        let checkOptionPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [checkOptionPrompt: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
