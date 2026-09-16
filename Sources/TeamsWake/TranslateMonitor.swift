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
    private var targetKeyCode: Int64 = 49
    private var targetMods: String = "none"
    private var requireCmd: Bool = false
    private var requireAlt: Bool = false
    private var requireCtrl: Bool = false
    private var requireShift: Bool = false
    private var isRightClickMode: Bool = false
    private var isSingleKeyMode: Bool = true
    public var isDetecting: Bool = false
    private var currentTranslationTask: Task<Void, Never>?

    private init() {}

    public func restartMonitoring(with shortcut: TranslationShortcut? = nil) {
        stopMonitoring()
        startMonitoring(with: shortcut)
    }

    public func syncShortcutConfig(with shortcut: TranslationShortcut) {
        self.targetKeyCode = shortcut.keyCode
        self.targetMods = shortcut.modifiers.lowercased()
        self.requireCmd = self.targetMods.contains("cmd")
        self.requireAlt = self.targetMods.contains("alt") || self.targetMods.contains("opt")
        self.requireCtrl = self.targetMods.contains("ctrl")
        self.requireShift = self.targetMods.contains("shift")
        self.isRightClickMode = (self.targetKeyCode == -2 || self.targetMods.contains("right_double") || self.targetMods.contains("double"))
        self.isSingleKeyMode = !self.isRightClickMode && !self.requireCmd && !self.requireAlt && !self.requireCtrl && !self.requireShift
    }

    public func startMonitoring(with shortcut: TranslationShortcut? = nil) {
        guard !isMonitoring else { return }

        // Sync shortcut configuration without triggering deadlocks
        if let sc = shortcut {
            self.syncShortcutConfig(with: sc)
        } else if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.syncShortcutConfig(with: AppState.shared.translationShortcut)
            }
        } else {
            Task { @MainActor in
                self.syncShortcutConfig(with: AppState.shared.translationShortcut)
            }
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
                    return Unmanaged.passUnretained(event)
                }

                // Dismiss HUD when clicking outside (do not dismiss when clicking inside HUD so buttons trigger properly)
                if type == .leftMouseDown {
                    if TranslateMonitor.isHudVisible {
                        let loc = event.location
                        // CGEvent global coordinates are anchored to the primary display's top-left,
                        // so the flip must use the primary screen height (NSScreen.main is the focused
                        // screen and can differ, causing in-HUD clicks to be misread as outside).
                        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080.0
                        let cocoaPoint = NSPoint(x: loc.x, y: primaryHeight - loc.y)
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
                    return Unmanaged.passUnretained(event)
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
                    return Unmanaged.passUnretained(event)
                }

                if type == .keyDown {
                    // Pass through if currently replaying previously intercepted key
                    if TranslateMonitor.shared.isReplayingKey {
                        return Unmanaged.passUnretained(event)
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
                                return Unmanaged.passUnretained(event)
                            }
                            let name = frontApp.localizedName?.lowercased() ?? ""
                            if name.contains("teamswake") || name.contains("teams wake") {
                                return Unmanaged.passUnretained(event)
                            }

                            // If already detecting, pass through immediately to avoid typing lag
                            if TranslateMonitor.shared.isDetecting {
                                return Unmanaged.passUnretained(event)
                            }

                            TranslateMonitor.shared.handleTrigger(shouldReplay: true)
                            return nil // Intercept native shortcut
                        }
                    }
                }

                return Unmanaged.passUnretained(event)
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
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        self.eventTap = nil
        self.runLoopSource = nil
        self.isMonitoring = false
    }

    public struct AXSelectionInfo {
        public let text: String?
        public let isZeroLengthCaret: Bool
        public let isCopyExplicitlyDisabled: Bool
    }

    /// Synchronously query currently focused UI element for selected text via macOS Accessibility API (< 1ms)
    public static func getSelectedTextViaAccessibility() -> AXSelectionInfo {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedAppVal: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppVal) == .success,
              let focusedApp = focusedAppVal else {
            return AXSelectionInfo(text: nil, isZeroLengthCaret: false, isCopyExplicitlyDisabled: false)
        }

        let appElement = focusedApp as! AXUIElement
        var focusedElementVal: AnyObject?
        let gotFocusedElement = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementVal) == .success

        if gotFocusedElement, let focusedElement = focusedElementVal {
            let element = focusedElement as! AXUIElement

            // 1. Direct selected text check
            var selectedTextVal: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextVal) == .success,
               let str = selectedTextVal as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return AXSelectionInfo(text: trimmed, isZeroLengthCaret: false, isCopyExplicitlyDisabled: false)
                }
            }

            // 2. Caret range check: if length == 0, caret is blinking in an input area with nothing selected
            var selectedRangeVal: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeVal) == .success,
               CFGetTypeID(selectedRangeVal) == AXValueGetTypeID() {
                let axVal = selectedRangeVal as! AXValue
                var range = CFRange()
                if AXValueGetValue(axVal, .cfRange, &range) && range.length == 0 {
                    return AXSelectionInfo(text: nil, isZeroLengthCaret: true, isCopyExplicitlyDisabled: false)
                }
            }
        }

        // 3. Inspect application menu bar Edit -> Copy item to see if Copy is explicitly disabled
        var copyDisabled = false
        var menuBarVal: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarVal) == .success,
           let menuBar = menuBarVal,
           let menus = copyAttribute(menuBar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] {
            for menu in menus {
                let title = (copyAttribute(menu, kAXTitleAttribute) as? String) ?? ""
                if title == "Edit" || title == "编辑" || title == "編輯" {
                    if let subLists = copyAttribute(menu, kAXChildrenAttribute) as? [AXUIElement],
                       let menuList = subLists.first,
                       let menuItems = copyAttribute(menuList, kAXChildrenAttribute) as? [AXUIElement] {
                        for item in menuItems {
                            let itemTitle = ((copyAttribute(item, kAXTitleAttribute) as? String) ?? "").trimmingCharacters(in: .whitespaces)
                            if itemTitle.hasPrefix("Copy") || itemTitle.hasPrefix("拷贝") || itemTitle.hasPrefix("复制") || itemTitle.hasPrefix("拷貝") {
                                if let enabled = copyAttribute(item, kAXEnabledAttribute) as? Bool, !enabled {
                                    copyDisabled = true
                                }
                                break
                            }
                        }
                    }
                    break
                }
            }
        }

        return AXSelectionInfo(text: nil, isZeroLengthCaret: false, isCopyExplicitlyDisabled: copyDisabled)
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success {
            return value
        }
        return nil
    }

    private var lastText: String = ""
    private var lastFrontPid: pid_t = 0
    private var lastForcedDirection: String? = nil

    public func cancelCurrentTranslation() {
        currentTranslationTask?.cancel()
        currentTranslationTask = nil
    }

    @MainActor
    public func toggleDirectionAndRetranslate() {
        guard !lastText.isEmpty else { return }
        let currentDirection = TranslationHudController.shared.model.direction
        let newDirection = (currentDirection == "ZH ➔ EN") ? "EN ➔ ZH" : "ZH ➔ EN"
        triggerDirectTranslation(text: lastText, frontPid: lastFrontPid, forcedDirection: newDirection)
    }

    public func retryTranslation() {
        guard !lastText.isEmpty else { return }
        triggerDirectTranslation(text: lastText, frontPid: lastFrontPid, forcedDirection: lastForcedDirection)
    }

    public func triggerDirectTranslation(text: String, frontPid: pid_t, forcedDirection: String? = nil) {
        lastText = text
        lastFrontPid = frontPid
        lastForcedDirection = forcedDirection
        currentTranslationTask?.cancel()

        // 1. Immediately show Loading HUD on MainActor (0ms feedback!)
        DispatchQueue.main.async {
            TranslationHudController.shared.showLoading(original: text, targetPid: frontPid, forcedDirection: forcedDirection)
        }

        currentTranslationTask = Task {
            do {
                let provider = await AppState.shared.translationProvider
                let res = try await TranslationEngine.shared.translate(text: text, provider: provider, forcedDirection: forcedDirection)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    TranslationHudController.shared.updateTranslation(
                        translated: res.result,
                        direction: res.direction,
                        provider: res.actualProvider
                    )
                    AppState.shared.addLog(message: "[Translation (\(res.actualProvider))] \"\(text.prefix(20))...\" ➔ \"\(res.result.prefix(20))...\"", type: .info)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    TranslationHudController.shared.showError(message: error.localizedDescription)
                    AppState.shared.addLog(message: "Translation failed: \(error.localizedDescription)", type: .error)
                }
            }
        }
    }

    private func handleTrigger(shouldReplay: Bool) {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        triggerSelectionTranslation(frontPid: frontPid, shouldReplay: shouldReplay)
    }

    private func triggerSelectionTranslation(frontPid: pid_t, shouldReplay: Bool) {
        guard !isDetecting else { return }
        isDetecting = true

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            defer {
                self?.isDetecting = false
            }

            // 1. Try Accessibility API first (silent, zero pasteboard interference, no NSBeep)
            let axInfo = TranslateMonitor.getSelectedTextViaAccessibility()
            if let text = axInfo.text, !text.isEmpty {
                self?.triggerDirectTranslation(text: text, frontPid: frontPid)
                return
            }

            // 2. If caret is blinking in an input box with 0-length selection, user is just typing
            if axInfo.isZeroLengthCaret {
                if shouldReplay {
                    self?.replayTargetKey()
                }
                return
            }

            // 3. If Copy menu item is explicitly disabled, Cmd+C will cause macOS NSBeep alert sound!
            if axInfo.isCopyExplicitlyDisabled {
                if shouldReplay {
                    self?.replayTargetKey()
                }
                return
            }

            // 4. Fallback: only simulate Cmd+C when AX could not determine selection (e.g. non-standard views)
            let oldChangeCount = NSPasteboard.general.changeCount
            self?.simulateCmdC()

            let start = Date()
            var detectedNewText = false
            while Date().timeIntervalSince(start) < 0.10 {
                if NSPasteboard.general.changeCount != oldChangeCount {
                    detectedNewText = true
                    break
                }
                usleep(10_000)
            }

            if detectedNewText, let rawStr = NSPasteboard.general.string(forType: .string) {
                let trimmed = rawStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self?.triggerDirectTranslation(text: trimmed, frontPid: frontPid)
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
        usleep(10_000)
        cDown?.post(tap: .cghidEventTap)
        usleep(15_000)
        cUp?.post(tap: .cghidEventTap)
        usleep(10_000)
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
        usleep(3_000)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.isReplayingKey = false
        }
    }
}
