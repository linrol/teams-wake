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

    private var panel: NonActivatingPanel?
    private var dismissTimer: Timer?
    private var currentData: TranslationHudData?
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

    public func show(original: String, translated: String, direction: String, provider: String, targetPid: pid_t, at point: CGPoint? = nil) {
        dismissTimer?.invalidate()
        speechSynthesizer?.stopSpeaking()

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

        guard let p = panel else { return }

        let data = TranslationHudData(
            original: original,
            translated: translated,
            direction: direction,
            provider: provider,
            targetPid: targetPid
        )
        self.currentData = data

        let rootView = TranslationHudView(
            data: data,
            onReplace: { [weak self] in
                self?.replaceSelection(with: translated, in: targetPid)
            },
            onCopy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.declareTypes([.string], owner: nil)
                NSPasteboard.general.setString(translated, forType: .string)
            },
            onSpeak: { [weak self] in
                self?.toggleSpeech(for: translated)
            },
            onClose: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = ClickThroughHostingView(rootView: rootView)
        hostingView.layoutSubtreeIfNeeded()

        let fittingSize = hostingView.fittingSize
        let targetWidth = max(285, fittingSize.width > 0 ? fittingSize.width : 360)
        let targetHeight = max(110, min(500, fittingSize.height > 0 ? fittingSize.height : 200))

        p.contentView = hostingView
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

        // Auto-dismiss timer (read user configured delay, 0 means never dismiss)
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
        currentData = nil
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
        guard let data = currentData else { return }
        replaceSelection(with: data.translated, in: data.targetPid)
    }

    private var isReplacing: Bool = false

    private func replaceSelection(with text: String, in pid: pid_t) {
        guard !isReplacing else { return }
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
    let data: TranslationHudData
    let onReplace: () -> Void
    let onCopy: () -> Void
    let onSpeak: () -> Void
    let onClose: () -> Void

    @State private var isCopied: Bool = false

    private var cardWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        
        // Measure the physical width of each line in the translated text
        let transLines = data.translated.components(separatedBy: "\n")
        var maxLineWidth: CGFloat = 0
        for line in transLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let w = (trimmed as NSString).size(withAttributes: [.font: font]).width
            if w > maxLineWidth {
                maxLineWidth = w
            }
        }
        
        // If translated text is very short, also check the first line of the original text
        if maxLineWidth < 180 {
            let origFont = NSFont.systemFont(ofSize: 11.5)
            let firstOrig = data.original.components(separatedBy: "\n").first ?? ""
            let origW = (firstOrig as NSString).size(withAttributes: [.font: origFont]).width
            maxLineWidth = max(maxLineWidth, min(240, origW))
        }
        
        // Add horizontal padding (14 on each side = 28) + margin allowance (14) = 42
        let neededWidth = ceil(maxLineWidth) + 42
        
        // Boundaries:
        // Min 285pt: ensures header and action buttons fit comfortably without crowding
        // Max 450pt: caps unbounded width for long continuous text paragraphs
        return max(285, min(450, neededWidth))
    }

    private var isLongText: Bool {
        data.translated.count > 180 || data.translated.contains("\n\n") || data.translated.components(separatedBy: "\n").count > 6
    }

    @ViewBuilder
    private var textContentView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Original Text (compact single-line preview with subtle styling)
            Text(data.original.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)

            Divider()
                .opacity(0.35)

            // Translated Text (comfortable line spacing for high readability)
            Text(data.translated)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineSpacing(3.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "character.book.closed.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                    Text(data.direction)
                        .font(.system(size: 11, weight: .bold))
                }

                Spacer()

                // Pronounce TTS Button
                Button(action: onSpeak) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Pronounce translated text")

                Text(data.provider)
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
