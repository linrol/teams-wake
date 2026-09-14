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

    /// Perform a 1-pixel micro-movement to reset IOHIDSystem idle time and restore within 20ms
    @discardableResult
    public func performMicroWiggle() -> Bool {
        let loc = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.size.height ?? 1080.0
        let currentY = screenHeight - loc.y
        let pt1 = CGPoint(x: loc.x + 1, y: currentY + 1)
        let pt2 = CGPoint(x: loc.x, y: currentY)

        // 1. Move cursor 1 pixel and post mouse move event to HID event tap
        CGWarpMouseCursorPosition(pt1)
        if let ev1 = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt1, mouseButton: .left) {
            ev1.post(tap: .cghidEventTap)
        }

        // 2. Sleep 20ms
        usleep(20_000)

        // 3. Immediately restore cursor position
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
