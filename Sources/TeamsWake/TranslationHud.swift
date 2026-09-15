import SwiftUI
import AppKit

public struct TranslationHudData: Identifiable {
    public let id = UUID()
    public let original: String
    public let translated: String
    public let direction: String
    public let provider: String
    public let targetPid: pid_t
}

@MainActor
public final class TranslationHudModel: ObservableObject {
    @Published public var original: String = ""
    @Published public var translated: String = ""
    @Published public var direction: String = ""
    @Published public var provider: String = ""
    @Published public var targetPid: pid_t = 0
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String? = nil

    public init(
        original: String = "",
        translated: String = "",
        direction: String = "",
        provider: String = "",
        targetPid: pid_t = 0,
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) {
        self.original = original
        self.translated = translated
        self.direction = direction
        self.provider = provider
        self.targetPid = targetPid
        self.isLoading = isLoading
        self.errorMessage = errorMessage
    }
}

/// Core: Native floating panel that never steals focus
/// Ensures active text selection and cursor are preserved when clicking panel buttons!
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

@MainActor
public final class TranslationHudController: NSObject {
    public static let shared = TranslationHudController()

    public let model = TranslationHudModel()
    private var panel: NonActivatingPanel?
    private var hostingView: ClickThroughHostingView<TranslationHudView>?
    private var dismissTimer: Timer?
    private var speechSynthesizer: NSSpeechSynthesizer?

    private override init() {
        super.init()
    }

    public func updateOpacity(_ opacity: Double) {
        panel?.alphaValue = CGFloat(opacity)
    }

    public func toggleSpeech(for text: String) {
        if speechSynthesizer == nil {
            speechSynthesizer = NSSpeechSynthesizer()
        }
        guard let synth = speechSynthesizer else { return }
        if synth.isSpeaking {
            synth.stopSpeaking()
        } else {
            synth.startSpeaking(text)
        }
    }

    private func createRootView() -> TranslationHudView {
        return TranslationHudView(
            model: model,
            onToggleDirection: {
                TranslateMonitor.shared.toggleDirectionAndRetranslate()
            },
            onReplace: { [weak self] in
                guard let self = self else { return }
                self.replaceSelection(with: self.model.translated, in: self.model.targetPid)
            },
            onCopy: { [weak self] in
                guard let self = self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.declareTypes([.string], owner: nil)
                NSPasteboard.general.setString(self.model.translated, forType: .string)
            },
            onSpeak: { [weak self] in
                guard let self = self else { return }
                self.toggleSpeech(for: self.model.translated)
            },
            onRetry: {
                TranslateMonitor.shared.retryTranslation()
            },
            onClose: { [weak self] in
                self?.hide()
            }
        )
    }

    private func ensurePanelCreated() {
        if panel == nil {
            let p = NonActivatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                backing: .buffered,
                defer: false
            )
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            self.panel = p
        }
    }

    /// Instant feedback: Show HUD immediately with loading indicator (0ms latency)
    public func showLoading(original: String, targetPid: pid_t, forcedDirection: String? = nil, at point: CGPoint? = nil) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        speechSynthesizer?.stopSpeaking()

        let direction: String
        if let forced = forcedDirection {
            direction = forced
        } else {
            let isZh = TranslationEngine.isChineseDominant(original)
            direction = isZh ? "ZH ➔ EN" : "EN ➔ ZH"
        }

        model.original = original
        model.translated = ""
        model.direction = direction
        model.provider = "Translating..."
        model.targetPid = targetPid
        model.isLoading = true
        model.errorMessage = nil

        if let p = panel, p.isVisible {
            updatePanelContentAndGeometry()
        } else {
            presentPanel(at: point)
        }
    }

    /// Update HUD in-place when async translation completes, dynamically resizing window
    public func updateTranslation(translated: String, direction: String, provider: String) {
        model.translated = translated
        model.direction = direction
        model.provider = provider
        model.isLoading = false
        model.errorMessage = nil

        updatePanelContentAndGeometry()
        startAutoDismissTimer()
    }

    /// Show error message in-place with retry button
    public func showError(message: String) {
        model.isLoading = false
        model.errorMessage = message
        model.provider = "Failed"

        updatePanelContentAndGeometry()
    }

    /// Direct display without loading state (backwards compatibility)
    public func show(original: String, translated: String, direction: String, provider: String, targetPid: pid_t, at point: CGPoint? = nil) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        speechSynthesizer?.stopSpeaking()

        model.original = original
        model.translated = translated
        model.direction = direction
        model.provider = provider
        model.targetPid = targetPid
        model.isLoading = false
        model.errorMessage = nil

        if let p = panel, p.isVisible {
            updatePanelContentAndGeometry()
        } else {
            presentPanel(at: point)
        }
        startAutoDismissTimer()
    }

    private func presentPanel(at point: CGPoint? = nil) {
        ensurePanelCreated()
        guard let p = panel else { return }

        let hv = ClickThroughHostingView(rootView: createRootView())
        p.contentView = hv
        self.hostingView = hv

        hv.layoutSubtreeIfNeeded()
        let fittingSize = hv.fittingSize
        let targetWidth = max(285, fittingSize.width > 0 ? fittingSize.width : 360)
        let targetHeight = max(110, min(500, fittingSize.height > 0 ? fittingSize.height : 160))

        p.setContentSize(NSSize(width: targetWidth, height: targetHeight))

        // Position floating window with 4-edge smart boundary checks
        let mouseLoc = point ?? NSEvent.mouseLocation
        let screen = NSScreen.main?.visibleFrame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var posX = mouseLoc.x + 10
        var posY = mouseLoc.y - targetHeight - 15

        // Right edge overflow protection
        if posX + targetWidth > screen.maxX - 10 {
            posX = screen.maxX - targetWidth - 10
        }
        // Left edge boundary protection
        if posX < screen.minX + 10 {
            posX = screen.minX + 10
        }
        // Bottom edge overflow protection (flips above cursor)
        if posY < screen.minY + 15 {
            posY = mouseLoc.y + 25
        }
        // Top edge boundary protection
        if posY + targetHeight > screen.maxY - 10 {
            posY = screen.maxY - targetHeight - 10
        }

        p.setFrame(NSRect(x: posX, y: posY, width: targetWidth, height: targetHeight), display: true, animate: false)

        // Smooth fade-in animation
        p.alphaValue = 0
        p.orderFront(nil)
        let targetAlpha = CGFloat(AppState.shared.hudOpacity)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = targetAlpha
        }

        TranslateMonitor.isHudVisible = true
        TranslateMonitor.cachedHudFrame = p.frame
        TranslateMonitor.hudShownDate = Date()
    }

    public func updatePanelContentAndGeometry() {
        guard let p = panel, p.isVisible else { return }

        // Recreate hosting view with the updated model so layoutSubtreeIfNeeded can accurately compute new fittingSize
        let hv = ClickThroughHostingView(rootView: createRootView())
        p.contentView = hv
        self.hostingView = hv

        hv.layoutSubtreeIfNeeded()
        let fittingSize = hv.fittingSize
        let targetWidth = max(285, fittingSize.width > 0 ? fittingSize.width : 360)
        let targetHeight = max(110, min(500, fittingSize.height > 0 ? fittingSize.height : 200))

        var frame = p.frame
        let heightDiff = targetHeight - frame.height
        frame.origin.y -= heightDiff
        frame.size.width = targetWidth
        frame.size.height = targetHeight

        let screen = NSScreen.main?.visibleFrame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if frame.maxX > screen.maxX - 10 {
            frame.origin.x = screen.maxX - frame.width - 10
        }
        if frame.minX < screen.minX + 10 {
            frame.origin.x = screen.minX + 10
        }
        if frame.minY < screen.minY + 15 {
            frame.origin.y = screen.minY + 15
        }
        if frame.maxY > screen.maxY - 10 {
            frame.origin.y = screen.maxY - frame.height - 10
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().setFrame(frame, display: true)
        }
        TranslateMonitor.cachedHudFrame = frame
    }

    private func startAutoDismissTimer() {
        dismissTimer?.invalidate()
        let delay = Double(AppState.shared.translationDismissSeconds)
        if delay > 0 {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.hide()
                }
            }
        }
    }

    public func hide() {
        guard let p = panel, p.isVisible else { return }
        dismissTimer?.invalidate()
        dismissTimer = nil
        TranslateMonitor.isHudVisible = false
        TranslateMonitor.cachedHudFrame = .zero
        TranslateMonitor.shared.cancelCurrentTranslation()
        speechSynthesizer?.stopSpeaking()

        // Smooth fade-out animation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    /// Supports pressing Enter to trigger replacement directly
    public func triggerReplaceFromEnterKey() {
        guard !model.isLoading, !model.translated.isEmpty else { return }
        replaceSelection(with: model.translated, in: model.targetPid)
    }

    private var isReplacing: Bool = false

    private func replaceSelection(with text: String, in pid: pid_t) {
        guard !isReplacing, !text.isEmpty else { return }
        isReplacing = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.isReplacing = false
            }
        }

        // 1. Hide HUD floating window first to yield screen overlay
        hide()

        // 2. Write translated text to system pasteboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.declareTypes([.string], owner: nil)
        NSPasteboard.general.setString(text, forType: .string)

        // 3. Ensure target frontmost application is active and focused
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            }
        }

        // 4. Wait 60ms for focus transition, then post physical Cmd + V on background thread
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.postCmdVPaste()
        }
    }

    private nonisolated func postCmdVPaste() {
        let src = CGEventSource(stateID: .hidSystemState)

        // Command key down (0x37)
        let modDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)
        modDown?.flags = .maskCommand

        // V key down (0x09)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand

        // V key up (0x09)
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand

        // Command key up (0x37)
        let modUp = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)
        modUp?.flags = []

        // Post single Cmd + V sequence to system HID event tap
        modDown?.post(tap: .cghidEventTap)
        usleep(15_000)

        vDown?.post(tap: .cghidEventTap)
        usleep(25_000)

        vUp?.post(tap: .cghidEventTap)
        usleep(15_000)

        modUp?.post(tap: .cghidEventTap)
    }
}

public struct TranslationHudView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var model: TranslationHudModel
    let onToggleDirection: () -> Void
    let onReplace: () -> Void
    let onCopy: () -> Void
    let onSpeak: () -> Void
    let onRetry: () -> Void
    let onClose: () -> Void

    @State private var isCopied: Bool = false
    @State private var isHoveringDirection: Bool = false

    private var cardWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        
        let sampleText = (model.isLoading || model.translated.isEmpty) ? model.original : model.translated
        let transLines = sampleText.components(separatedBy: "\n")
        var maxLineWidth: CGFloat = 0
        for line in transLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let w = (trimmed as NSString).size(withAttributes: [.font: font]).width
            if w > maxLineWidth {
                maxLineWidth = w
            }
        }
        
        if maxLineWidth < 180 {
            let origFont = NSFont.systemFont(ofSize: 11.5)
            let firstOrig = model.original.components(separatedBy: "\n").first ?? ""
            let origW = (firstOrig as NSString).size(withAttributes: [.font: origFont]).width
            maxLineWidth = max(maxLineWidth, min(240, origW))
        }
        
        let neededWidth = ceil(maxLineWidth) + 42
        return max(285, min(450, neededWidth))
    }

    private var isLongText: Bool {
        model.translated.count > 180 || model.translated.contains("\n\n") || model.translated.components(separatedBy: "\n").count > 6
    }

    @ViewBuilder
    private var textContentView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Original Text (compact single-line preview with subtle styling)
            Text(model.original.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)

            Divider()
                .opacity(0.35)

            if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 16, height: 16)
                    Text("Translating...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.vertical, 4)
            } else if let errorMsg = model.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text(errorMsg)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button(action: onRetry) {
                        Text("Retry")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.vertical, 4)
            } else {
                // Translated Text (comfortable line spacing for high readability)
                Text(model.translated)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineSpacing(3.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                // Entire direction pill is clickable to reverse direction
                Button(action: onToggleDirection) {
                    HStack(spacing: 5) {
                        Image(systemName: "character.book.closed.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                        Text(model.direction)
                            .font(.system(size: 11, weight: .bold))
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(isHoveringDirection ? .accentColor : .secondary.opacity(0.8))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(isHoveringDirection ? 0.20 : 0.10))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHoveringDirection = hovering
                }
                .help("Switch translation direction (ZH ⇄ EN)")

                Spacer()

                if !model.isLoading && !model.translated.isEmpty {
                    // Pronounce TTS Button
                    Button(action: onSpeak) {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Pronounce translated text")
                }

                Text(model.provider)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Text Content Area (dynamic expansion for short text, scrollable for long text)
            if isLongText {
                ScrollView(.vertical, showsIndicators: true) {
                    textContentView
                }
                .frame(maxHeight: 250)
            } else {
                textContentView
            }

            // Action Buttons (right-aligned compact display)
            HStack(spacing: 8) {
                Spacer()

                Button(action: onReplace) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Replace")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isLoading || model.translated.isEmpty)

                Button(action: {
                    onCopy()
                    isCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        onClose()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "Copied" : "Copy")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(isCopied ? .green : .primary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isLoading || model.translated.isEmpty)
            }
        }
        .padding(14)
        .frame(width: cardWidth)
        .background(
            ZStack {
                VisualEffectView(material: .popover, blendingMode: .behindWindow, cornerRadius: 14)
                Color(nsColor: .windowBackgroundColor).opacity(0.3)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 15, x: 0, y: 6)
    }
}
