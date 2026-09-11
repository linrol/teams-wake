import Foundation
import Cocoa
import CoreGraphics

var targetFilter: String = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : "all"
var targetKeyCode: Int64 = CommandLine.arguments.count > 2 ? (Int64(CommandLine.arguments[2]) ?? 125) : 125
var targetMods: String = CommandLine.arguments.count > 3 ? CommandLine.arguments[3].lowercased() : "none"

var requireCmd: Bool = targetMods.contains("cmd")
var requireAlt: Bool = targetMods.contains("alt") || targetMods.contains("opt")
var requireCtrl: Bool = targetMods.contains("ctrl")
var requireShift: Bool = targetMods.contains("shift")

func isTargetFrontmost() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication else { return false }
    let name = app.localizedName?.lowercased() ?? ""
    let bundle = app.bundleIdentifier?.lowercased() ?? ""

    // Never intercept inside Teams Wake itself
    if name.contains("teams wake") || bundle.contains("teamswake") {
        return false
    }

    if targetFilter == "all" || targetFilter == "*" { return true }
    return name.contains("teams") || bundle.contains("teams") || name.contains(targetFilter)
}

func containsChinese(_ text: String) -> Bool {
    return text.range(of: "\\p{Han}", options: .regularExpression) != nil
}

var isReplayingKey = false
var lastMouseDownPoint: CGPoint = .zero
var lastMouseUpPoint: CGPoint = .zero
var lastMouseUpTime: Date = Date.distantPast

func replayTargetKey() {
    isReplayingKey = true
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(targetKeyCode), keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(targetKeyCode), keyDown: false)
    var flag: CGEventFlags = []
    if requireCmd { flag.insert(.maskCommand) }
    if requireAlt { flag.insert(.maskAlternate) }
    if requireCtrl { flag.insert(.maskControl) }
    if requireShift { flag.insert(.maskShift) }
    down?.flags = flag
    up?.flags = flag
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

func postKeyCombination(virtualKey: CGKeyCode, modifier: CGKeyCode = 0x37) {
    let src = CGEventSource(stateID: .hidSystemState)
    let modDown = CGEvent(keyboardEventSource: src, virtualKey: modifier, keyDown: true)
    modDown?.flags = .maskCommand

    let keyDown = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true)
    keyDown?.flags = .maskCommand

    let keyUp = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)
    keyUp?.flags = .maskCommand

    let modUp = CGEvent(keyboardEventSource: src, virtualKey: modifier, keyDown: false)
    modUp?.flags = []

    modDown?.post(tap: .cghidEventTap)
    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)
    modUp?.post(tap: .cghidEventTap)
}

func simulateCmdC() {
    postKeyCombination(virtualKey: 0x08)
}

func simulateCmdV() {
    postKeyCombination(virtualKey: 0x09)
}

var isTrackpadMode: Bool = (targetKeyCode == -2 || targetMods.contains("trackpad"))

func isFrontmostAppEditable() -> Bool {
    // 1. Check system-wide focused element
    let systemWide = AXUIElementCreateSystemWide()
    var sysElem: CFTypeRef?
    if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &sysElem) == .success, let elem = sysElem {
        let axElem = elem as! AXUIElement
        var isSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(axElem, kAXValueAttribute as CFString, &isSettable) == .success, isSettable.boolValue {
            return true
        }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElem, kAXRoleAttribute as CFString, &role) == .success, let r = role as? String {
            let lower = r.lowercased()
            if lower.contains("textfield") || lower.contains("textarea") || lower.contains("searchfield") {
                return true
            }
        }
    }
    
    // 2. Check frontmost application focused element
    guard let app = NSWorkspace.shared.frontmostApplication else { return false }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var appElem: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &appElem) == .success, let elem = appElem {
        let axElem = elem as! AXUIElement
        var isSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(axElem, kAXValueAttribute as CFString, &isSettable) == .success, isSettable.boolValue {
            return true
        }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElem, kAXRoleAttribute as CFString, &role) == .success, let r = role as? String {
            let lower = r.lowercased()
            if lower.contains("textfield") || lower.contains("textarea") || lower.contains("searchfield") {
                return true
            }
        }
    }
    
    return false
}

func triggerSelectionTranslation(shouldReplayKey: Bool = false) {
    if !isTargetFrontmost() { return }

    let isEditable = isFrontmostAppEditable()

    DispatchQueue.global(qos: .userInteractive).async {
        let oldChangeCount = NSPasteboard.general.changeCount
        simulateCmdC()

        let start = Date()
        var detectedNewText = false
        while Date().timeIntervalSince(start) < 0.15 {
            if NSPasteboard.general.changeCount != oldChangeCount {
                detectedNewText = true
                break
            }
            usleep(5000)
        }

        if detectedNewText, let rawStr = NSPasteboard.general.string(forType: .string) {
            let str = rawStr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !str.isEmpty {
                let b64 = Data(str.utf8).base64EncodedString()
                
                // Calculate selection coordinates for positioning the translation bubble
                var minX = -1
                var maxX = -1
                var minY = -1
                var maxY = -1

                if Date().timeIntervalSince(lastMouseUpTime) < 30.0 && lastMouseDownPoint != .zero && lastMouseUpPoint != .zero {
                    minX = Int(min(lastMouseDownPoint.x, lastMouseUpPoint.x))
                    maxX = Int(max(lastMouseDownPoint.x, lastMouseUpPoint.x))
                    minY = Int(min(lastMouseDownPoint.y, lastMouseUpPoint.y))
                    maxY = Int(max(lastMouseDownPoint.y, lastMouseUpPoint.y))
                } else {
                    let loc = CGEvent(source: nil)?.location ?? .zero
                    if loc != .zero {
                        minX = Int(loc.x)
                        maxX = Int(loc.x)
                        minY = Int(loc.y)
                        maxY = Int(loc.y)
                    }
                }

                if containsChinese(str) {
                    print("TRANSLATE_REQ_ZH2EN \(b64) \(minX) \(maxX) \(minY) \(maxY) \(isEditable ? 1 : 0)")
                } else {
                    print("TRANSLATE_REQ_EN2ZH \(b64) \(minX) \(maxX) \(minY) \(maxY) \(isEditable ? 1 : 0)")
                }
                fflush(stdout)
                return
            }
        }

        // No text selected; replay target key if requested
        if shouldReplayKey {
            replayTargetKey()
        }
    }
}

// Background thread reading translation responses from Node.js
DispatchQueue.global(qos: .userInitiated).async {
    while let line = readLine() {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.starts(with: "PASTE_TRANSLATION ") {
            let b64 = String(trimmed.dropFirst("PASTE_TRANSLATION ".count))
            if let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.declareTypes([.string], owner: nil)
                    NSPasteboard.general.setString(text, forType: .string)
                    usleep(30000) // 30ms to let pasteboard register
                    simulateCmdV()
                    print("TRANSLATE_SUCCESS")
                    fflush(stdout)
                }
            }
        }
    }
}

let eventMask = (1 << CGEventType.keyDown.rawValue) | 
                (1 << CGEventType.leftMouseDown.rawValue) | 
                (1 << CGEventType.leftMouseUp.rawValue) | 
                (1 << CGEventType.rightMouseDown.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(eventMask),
    callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
        if type == .tapDisabledByTimeout {
            if let tap = refcon {
                let machPort = Unmanaged<CFMachPort>.fromOpaque(tap).takeUnretainedValue()
                CGEvent.tapEnable(tap: machPort, enable: true)
            }
            return nil
        }

        // Track drag-selection coordinates
        if type == .leftMouseDown {
            lastMouseDownPoint = event.location
            return Unmanaged.passRetained(event)
        }

        if type == .leftMouseUp {
            lastMouseUpPoint = event.location
            lastMouseUpTime = Date()
            return Unmanaged.passRetained(event)
        }

        // Handle Trackpad Two-Finger Double Click (Right Double-Click)
        if type == .rightMouseDown {
            if isTrackpadMode {
                let clickCount = event.getIntegerValueField(.mouseEventClickState)
                if clickCount == 2 {
                    triggerSelectionTranslation(shouldReplayKey: false)
                    return nil // Suppress double right-click context menu
                }
            }
            return Unmanaged.passRetained(event)
        }

        if type == .keyDown {
            if isReplayingKey {
                isReplayingKey = false
                return Unmanaged.passRetained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // Check for configurable Target Key
            if !isTrackpadMode && keyCode == targetKeyCode {
                let flags = event.flags
                let hasCmd = flags.contains(.maskCommand)
                let hasAlt = flags.contains(.maskAlternate)
                let hasCtrl = flags.contains(.maskControl)
                let hasShift = flags.contains(.maskShift)

                if hasCmd == requireCmd && hasAlt == requireAlt && hasCtrl == requireCtrl && hasShift == requireShift {
                    if !isTargetFrontmost() {
                        return Unmanaged.passRetained(event)
                    }

                    triggerSelectionTranslation(shouldReplayKey: true)
                    return nil
                }
            }
            return Unmanaged.passRetained(event)
        }

        return Unmanaged.passRetained(event)
    },
    userInfo: nil
) else {
    print("FAILED_TO_CREATE_TAP")
    fflush(stdout)
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// Also listen for Trackpad Two-Finger Double-Tap (Smart Magnify) gesture
if isTrackpadMode {
    _ = NSApplication.shared
    NSEvent.addGlobalMonitorForEvents(matching: [.smartMagnify]) { _ in
        triggerSelectionTranslation(shouldReplayKey: false)
    }
}

print("READY")
fflush(stdout)
CFRunLoopRun()
