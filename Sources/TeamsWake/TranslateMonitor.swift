import Foundation
import Cocoa
import CoreGraphics

public final class TranslateMonitor {
    public static let shared = TranslateMonitor()
    public static var isHudVisible: Bool = false
    public static var cachedHudFrame: NSRect = .zero
    public static var hudShownDate: Date = .distantPast

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isReplayingKey: Bool = false
    public var isMonitoring: Bool = false

    // Right-click / Trackpad double tap tracking
    private var lastRightMouseDownTime: Date = Date.distantPast
    private var lastRightMouseDownPoint: CGPoint = .zero

    // Shortcut configuration cache
    private var targetKeyCode: Int64 = 125
    private var targetMods: String = "none"
    private var requireCmd: Bool = false
    private var requireAlt: Bool = false
    private var requireCtrl: Bool = false
    private var requireShift: Bool = false
    private var isRightClickMode: Bool = false

    private init() {}

    public func restartMonitoring() {
        stopMonitoring()
        startMonitoring()
    }

    public func startMonitoring() {
        guard !isMonitoring else { return }

        // Sync shortcut configuration
        Task { @MainActor in
            let sc = AppState.shared.translationShortcut
            self.targetKeyCode = sc.keyCode
            self.targetMods = sc.modifiers.lowercased()
            self.requireCmd = self.targetMods.contains("cmd")
            self.requireAlt = self.targetMods.contains("alt") || self.targetMods.contains("opt")
            self.requireCtrl = self.targetMods.contains("ctrl")
            self.requireShift = self.targetMods.contains("shift")
            self.isRightClickMode = (self.targetKeyCode == -2 || self.targetMods.contains("right_double") || self.targetMods.contains("double"))
        }

        var mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
        mask |= (1 << CGEventType.rightMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                if type == .tapDisabledByUserInput {
                    return nil
                }
                if type == .tapDisabledByTimeout {
                    if let port = TranslateMonitor.shared.eventTap {
                        CGEvent.tapEnable(tap: port, enable: true)
                    }
                    return nil
                }

                // Dismiss HUD when clicking outside (do not dismiss when clicking inside HUD so buttons trigger properly)
                if type == .leftMouseDown {
                    if TranslateMonitor.isHudVisible {
                        let loc = event.location
                        let screenHeight = NSScreen.main?.frame.height ?? 1080.0
                        let cocoaPoint = NSPoint(x: loc.x, y: screenHeight - loc.y)
                        let hitRect = TranslateMonitor.cachedHudFrame.insetBy(dx: -8, dy: -8)

                        // Only dismiss when click point is outside HUD window and HUD has been shown for > 150ms
                        if !hitRect.contains(cocoaPoint) {
                            if Date().timeIntervalSince(TranslateMonitor.hudShownDate) > 0.15 {
                                DispatchQueue.main.async {
                                    TranslationHudController.shared.hide()
                                }
                            }
                        }
                    }
                    return Unmanaged.passRetained(event)
                }

                // Handle right double click / trackpad two-finger double tap
                if type == .rightMouseDown {
                    if TranslateMonitor.shared.isRightClickMode {
                        let now = Date()
                        let timeDiff = now.timeIntervalSince(TranslateMonitor.shared.lastRightMouseDownTime)
                        let dx = event.location.x - TranslateMonitor.shared.lastRightMouseDownPoint.x
                        let dy = event.location.y - TranslateMonitor.shared.lastRightMouseDownPoint.y
                        let dist = sqrt(dx * dx + dy * dy)
                        let clickCount = event.getIntegerValueField(.mouseEventClickState)

                        if clickCount >= 2 || (timeDiff < 0.50 && dist < 65.0) {
                            TranslateMonitor.shared.lastRightMouseDownTime = Date.distantPast
                            TranslateMonitor.shared.lastRightMouseDownPoint = .zero
                            TranslateMonitor.shared.handleTrigger(shouldReplay: false)
                            return nil // Suppress right click context menu
                        } else {
                            TranslateMonitor.shared.lastRightMouseDownTime = now
                            TranslateMonitor.shared.lastRightMouseDownPoint = event.location
                        }
                    }
                    return Unmanaged.passRetained(event)
                }

                if type == .keyDown {
                    // Pass through if currently replaying previously intercepted key
                    if TranslateMonitor.shared.isReplayingKey {
                        TranslateMonitor.shared.isReplayingKey = false
                        return Unmanaged.passRetained(event)
                    }

                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

                    // Esc key dismisses HUD
                    if TranslateMonitor.isHudVisible && keyCode == 53 {
                        DispatchQueue.main.async {
                            TranslationHudController.shared.hide()
                        }
                        return nil
                    }

                    // Enter key (36) or Numpad enter (76) triggers replace directly
                    if TranslateMonitor.isHudVisible && (keyCode == 36 || keyCode == 76) {
                        DispatchQueue.main.async {
                            TranslationHudController.shared.triggerReplaceFromEnterKey()
                        }
                        return nil
                    }

                    // Match target shortcut
                    if !TranslateMonitor.shared.isRightClickMode && keyCode == TranslateMonitor.shared.targetKeyCode {
                        let flags = event.flags
                        let hasCmd = flags.contains(.maskCommand)
                        let hasAlt = flags.contains(.maskAlternate)
                        let hasCtrl = flags.contains(.maskControl)
                        let hasShift = flags.contains(.maskShift)

                        let m = TranslateMonitor.shared
                        if hasCmd == m.requireCmd && hasAlt == m.requireAlt && hasCtrl == m.requireCtrl && hasShift == m.requireShift {
                            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                                return Unmanaged.passRetained(event)
                            }
                            let name = frontApp.localizedName?.lowercased() ?? ""
                            if name.contains("teamswake") || name.contains("teams wake") {
                                return Unmanaged.passRetained(event)
                            }

                            TranslateMonitor.shared.handleTrigger(shouldReplay: true)
                            return nil // Intercept native shortcut
                        }
                    }
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: nil
        ) else {
            print("Failed to create translate event tap")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.isMonitoring = true
    }

    public func stopMonitoring() {
        guard isMonitoring else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        self.eventTap = nil
        self.runLoopSource = nil
        self.isMonitoring = false
    }

    private func handleTrigger(shouldReplay: Bool) {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        triggerSelectionTranslation(frontPid: frontPid, shouldReplay: shouldReplay)
    }

    private func triggerSelectionTranslation(frontPid: pid_t, shouldReplay: Bool) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let oldChangeCount = NSPasteboard.general.changeCount
            self?.simulateCmdC()

            let start = Date()
            var detectedNewText = false
            while Date().timeIntervalSince(start) < 0.22 {
                if NSPasteboard.general.changeCount != oldChangeCount {
                    detectedNewText = true
                    break
                }
                usleep(5000)
            }

            if detectedNewText, let rawStr = NSPasteboard.general.string(forType: .string) {
                let trimmed = rawStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    Task {
                        do {
                            let provider = await AppState.shared.translationProvider
                            let res = try await TranslationEngine.shared.translate(text: trimmed, provider: provider)
                            await MainActor.run {
                                TranslationHudController.shared.show(
                                    original: trimmed,
                                    translated: res.result,
                                    direction: res.direction,
                                    provider: res.actualProvider,
                                    targetPid: frontPid
                                )
                                AppState.shared.addLog(message: "[Translation (\(res.actualProvider))] \"\(trimmed.prefix(20))...\" ➔ \"\(res.result.prefix(20))...\"", type: .info)
                            }
                        } catch {
                            await MainActor.run {
                                AppState.shared.addLog(message: "Translation failed: \(error.localizedDescription)", type: .error)
                            }
                        }
                    }
                    return
                }
            }

            // If no text selected, replay native key to avoid dropping key press
            if shouldReplay {
                self?.replayTargetKey()
            }
        }
    }

    private func simulateCmdC() {
        let src = CGEventSource(stateID: .hidSystemState)
        let modDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)
        modDown?.flags = .maskCommand

        let cDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)
        cDown?.flags = .maskCommand

        let cUp = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        cUp?.flags = .maskCommand

        let modUp = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)
        modUp?.flags = []

        modDown?.post(tap: .cghidEventTap)
        usleep(15_000)
        cDown?.post(tap: .cghidEventTap)
        usleep(25_000)
        cUp?.post(tap: .cghidEventTap)
        usleep(15_000)
        modUp?.post(tap: .cghidEventTap)
    }

    private func replayTargetKey() {
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
}
