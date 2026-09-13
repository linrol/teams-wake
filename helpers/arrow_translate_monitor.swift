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
var lastRightMouseDownTime: Date = Date.distantPast
var lastRightMouseDownPoint: CGPoint = .zero

// HUD Tracking for Click-Outside Dismissal
var isHudVisible = false
var hudMinX: CGFloat = 0
var hudMaxX: CGFloat = 0
var hudMinY: CGFloat = 0
var hudMaxY: CGFloat = 0
var hudShownTime: Date = Date.distantPast

func dismissContextMenu() {
    let src = CGEventSource(stateID: .hidSystemState)
    let escDown = CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)
    let escUp = CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)
    escDown?.post(tap: .cghidEventTap)
    escUp?.post(tap: .cghidEventTap)
}

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
    usleep(15000)
    keyDown?.post(tap: .cghidEventTap)
    usleep(25000)
    keyUp?.post(tap: .cghidEventTap)
    usleep(15000)
    modUp?.post(tap: .cghidEventTap)
}

func simulateCmdC() {
    postKeyCombination(virtualKey: 0x08)
}

func simulateCmdV() {
    postKeyCombination(virtualKey: 0x09)
}

var isTrackpadMode: Bool = (targetKeyCode == -2 || targetMods.contains("trackpad") || targetMods.contains("right_double") || targetMods.contains("double"))

func triggerSelectionTranslation(shouldReplayKey: Bool = false) {
    if !isTargetFrontmost() { return }

    let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

    DispatchQueue.global(qos: .userInteractive).async {
        if isTrackpadMode {
            usleep(35000) // 35ms delay to allow context menu dismiss
        }
        let oldChangeCount = NSPasteboard.general.changeCount
        simulateCmdC()

        let start = Date()
        var detectedNewText = false
        while Date().timeIntervalSince(start) < 0.20 {
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
                    print("TRANSLATE_REQ_ZH2EN \(b64) \(minX) \(maxX) \(minY) \(maxY) \(frontPid)")
                } else {
                    print("TRANSLATE_REQ_EN2ZH \(b64) \(minX) \(maxX) \(minY) \(maxY) \(frontPid)")
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
        if trimmed.starts(with: "REPLACE_SELECTION ") {
            let parts = trimmed.dropFirst("REPLACE_SELECTION ".count).split(separator: " ")
            if parts.count >= 2 {
                let pidStr = String(parts[0])
                let b64 = String(parts[1])
                if let pid = pid_t(pidStr), let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        if pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
                            if #available(macOS 14.0, *) {
                                app.activate()
                            } else {
                                app.activate(options: [.activateIgnoringOtherApps])
                            }
                        }
                        usleep(60000) // 60ms to let target application gain active focus
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.declareTypes([.string], owner: nil)
                        NSPasteboard.general.setString(text, forType: .string)
                        usleep(30000) // 30ms to register pasteboard
                        simulateCmdV()
                        print("TRANSLATE_SUCCESS")
                        fflush(stdout)
                    }
                }
            }
        } else if trimmed.starts(with: "PASTE_TRANSLATION ") {
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
        } else if trimmed.starts(with: "HUD_FRAME ") {
            let parts = trimmed.dropFirst("HUD_FRAME ".count).split(separator: " ")
            if parts.count >= 4,
               let x = Double(parts[0]),
               let y = Double(parts[1]),
               let w = Double(parts[2]),
               let h = Double(parts[3]) {
                hudMinX = CGFloat(x)
                hudMaxX = CGFloat(x + w)
                hudMinY = CGFloat(y)
                hudMaxY = CGFloat(y + h)
                hudShownTime = Date()
                isHudVisible = true
            }
        } else if trimmed == "HUD_CLOSED" {
            isHudVisible = false
        }
    }
    // Parent Electron process closed stdin, exit cleanly
    exit(0)
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

        // Check for click-outside to auto-dismiss Translation HUD
        if isHudVisible && Date().timeIntervalSince(hudShownTime) > 0.15 {
            if type == .leftMouseDown || type == .rightMouseDown {
                let p = event.location
                if p.x < hudMinX || p.x > hudMaxX || p.y < hudMinY || p.y > hudMaxY {
                    isHudVisible = false
                    print("HUD_CLICK_OUTSIDE")
                    fflush(stdout)
                }
            }
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
                let now = Date()
                let timeDiff = now.timeIntervalSince(lastRightMouseDownTime)
                let dx = event.location.x - lastRightMouseDownPoint.x
                let dy = event.location.y - lastRightMouseDownPoint.y
                let dist = sqrt(dx * dx + dy * dy)
                let clickCount = event.getIntegerValueField(.mouseEventClickState)

                // Trigger on macOS clickCount == 2 OR consecutive right clicks within 0.5s and 65px radius
                if clickCount >= 2 || (timeDiff < 0.50 && dist < 65.0) {
                    lastRightMouseDownTime = Date.distantPast
                    lastRightMouseDownPoint = .zero
                    dismissContextMenu()
                    triggerSelectionTranslation(shouldReplayKey: false)
                    return nil // Suppress double right-click context menu
                } else {
                    lastRightMouseDownTime = now
                    lastRightMouseDownPoint = event.location
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
        dismissContextMenu()
        triggerSelectionTranslation(shouldReplayKey: false)
    }
}

print("READY")
fflush(stdout)
CFRunLoopRun()
