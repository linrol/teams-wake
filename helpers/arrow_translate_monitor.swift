import Foundation
import Cocoa
import CoreGraphics

var targetFilter: String = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : "teams"

func isTargetFrontmost() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication else { return false }
    if targetFilter == "all" || targetFilter == "*" { return true }
    let name = app.localizedName?.lowercased() ?? ""
    let bundle = app.bundleIdentifier?.lowercased() ?? ""
    return name.contains("teams") || bundle.contains("teams") || name.contains(targetFilter)
}

func containsChinese(_ text: String) -> Bool {
    return text.range(of: "\\p{Han}", options: .regularExpression) != nil
}

var isReplayingDownArrow = false
var lastMouseDownPoint: CGPoint = .zero
var lastMouseUpPoint: CGPoint = .zero
var lastMouseUpTime: Date = Date.distantPast

func replayDownArrow() {
    isReplayingDownArrow = true
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 125, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: 125, keyDown: false)
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

let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)

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

        if isReplayingDownArrow {
            isReplayingDownArrow = false
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // Check for Down Arrow (125 / 0x7D)
        if keyCode == 125 {
            let flags = event.flags
            let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
            if !modifiers.isEmpty {
                return Unmanaged.passRetained(event)
            }

            if !isTargetFrontmost() {
                return Unmanaged.passRetained(event)
            }

            // Target app is frontmost and Down Arrow was pressed.
            // Asynchronously probe selection so tap callback returns immediately (never blocks WindowServer)
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
                        if containsChinese(str) {
                            // Chinese text selected -> Translate ZH to EN, paste in-place
                            print("TRANSLATE_REQ_ZH2EN \(b64)")
                        } else {
                            // English / Foreign text selected -> Calculate selection coordinates
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
                            print("TRANSLATE_REQ_EN2ZH \(b64) \(minX) \(maxX) \(minY) \(maxY)")
                        }
                        fflush(stdout)
                        return
                    }
                }

                // No text selected; replay Down Arrow so normal navigation occurs
                replayDownArrow()
            }

            // Consume original Down Arrow immediately
            return nil
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
print("READY")
fflush(stdout)
CFRunLoopRun()
