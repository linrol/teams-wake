import SwiftUI
import AppKit

public struct MenuBarPopup: View {
    @ObservedObject var state = AppState.shared
    @State private var isScheduleExpanded: Bool = false
    @State private var isAddingSchedule: Bool = false
    @State private var newScheduleName: String = ""
    @State private var newStartTime: String = "19:00"
    @State private var newEndTime: String = "22:00"
    @State private var isLogsCopied: Bool = false
    @State private var isVersionCopied: Bool = false

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            // MARK: - Header & Main Toggle Card
            headerCard

            // MARK: - Permission Banner (if needed)
            if !state.hasAccessibilityPermission {
                permissionBanner
            }

            // MARK: - Interval Slider Card
            intervalCard

            // MARK: - Schedule Section
            scheduleCard

            // MARK: - Auto-Translate Section
            translationCard

            // MARK: - Logs View
            logsSection

            Divider()

            // MARK: - Bottom Actions
            bottomActions
        }
        .padding(14)
        .frame(width: 360)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .onAppear {
            state.checkPermission()
        }
    }

    // MARK: - Subviews
    private var headerCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(state.isActive ? Color.green.opacity(0.2) : Color.gray.opacity(0.15))
                    .frame(width: 38, height: 38)

                Image(systemName: state.isActive ? "bolt.fill" : "moon.stars.fill")
                    .font(.system(size: 18))
                    .foregroundColor(state.isActive ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Keep Alive")
                        .font(.system(size: 15, weight: .bold))
                    if state.isActive {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                    }
                }

                Text(state.isActive ? "Active (every \(state.intervalMinutes)m)" : "Stopped")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { state.isActive },
                set: { _ in state.toggleActive(manual: true) }
            ))
            .toggleStyle(SwitchToggleStyle(tint: .accentColor))
            .labelsHidden()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("Accessibility permission required for hardware micro-events")
                .font(.system(size: 11))
                .foregroundColor(.primary)
            Spacer()
            Button("Grant") {
                state.requestPermission()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.15))
        )
    }

    private var intervalCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Idle Reset Interval")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(state.intervalMinutes) min")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundColor(.accentColor)
                    .clipShape(Capsule())
            }

            Slider(
                value: Binding(
                    get: { Double(state.intervalMinutes) },
                    set: { state.intervalMinutes = Int($0) }
                ),
                in: 1...10,
                step: 1
            )
            .tint(.accentColor)

            HStack {
                Text("1m").font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text("3m").font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text("5m").font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text("8m").font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text("10m").font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        )
    }

    private var scheduleCard: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
                Text("Keep-Alive Schedule")
                    .font(.system(size: 12, weight: .medium))

                Spacer()

                Toggle("", isOn: $state.scheduleEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .labelsHidden()
                    .controlSize(.mini)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isScheduleExpanded.toggle()
                    }
                }) {
                    Image(systemName: isScheduleExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isScheduleExpanded {
                VStack(spacing: 6) {
                    ForEach($state.schedules) { $item in
                        HStack(spacing: 6) {
                            Toggle("", isOn: $item.enabled)
                                .toggleStyle(CheckboxToggleStyle())
                                .labelsHidden()

                            Text(item.name)
                                .font(.system(size: 11))
                            Spacer()
                            Text("\(item.startTime) - \(item.endTime)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)

                            Button(action: {
                                state.removeSchedule(id: item.id)
                            }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .help("Delete this schedule")
                        }
                        .padding(.vertical, 2)
                    }

                    Divider().opacity(0.3)

                    if isAddingSchedule {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("Name (e.g. Schedule 3)", text: $newScheduleName)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.mini)
                                    .font(.system(size: 11))

                                HStack(spacing: 2) {
                                    TextField("19:00", text: $newStartTime)
                                        .textFieldStyle(.roundedBorder)
                                        .controlSize(.mini)
                                        .frame(width: 46)
                                        .font(.system(size: 11))

                                    Text("-")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)

                                    TextField("22:00", text: $newEndTime)
                                        .textFieldStyle(.roundedBorder)
                                        .controlSize(.mini)
                                        .frame(width: 46)
                                        .font(.system(size: 11))
                                }
                            }

                            HStack {
                                Button("Cancel") {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isAddingSchedule = false
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)

                                Spacer()

                                Button("Save") {
                                    let name = newScheduleName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !name.isEmpty else { return }
                                    let s = newStartTime.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let e = newEndTime.trimmingCharacters(in: .whitespacesAndNewlines)
                                    state.addSchedule(name: name, startTime: s.isEmpty ? "09:00" : s, endTime: e.isEmpty ? "18:00" : e)
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isAddingSchedule = false
                                        newScheduleName = ""
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                                .disabled(newScheduleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.08))
                        )
                    } else {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isAddingSchedule = true
                                newScheduleName = "Schedule \(state.schedules.count + 1)"
                                newStartTime = "19:00"
                                newEndTime = "22:00"
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "plus.circle.fill")
                                Text("Add Schedule")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        )
    }

    private var translationCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "character.book.closed.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.accentColor)
                    Text("Auto Translation")
                        .font(.system(size: 12, weight: .medium))
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { state.isAutoTranslateActive },
                    set: { _ in state.toggleAutoTranslate() }
                ))
                .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                .labelsHidden()
                .controlSize(.mini)
            }

            if state.isAutoTranslateActive {
                VStack(spacing: 5) {
                    // Shortcut selection
                    HStack {
                        Text("Shortcut:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Spacer()

                        Picker("", selection: $state.translationShortcut) {
                            ForEach(TranslationShortcut.presets) { sc in
                                Text(sc.label).tag(sc)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.mini)
                    }

                    // Provider selection
                    HStack {
                        Text("Provider:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Spacer()

                        Picker("", selection: $state.translationProvider) {
                            ForEach(TranslationProvider.allCases) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.mini)
                    }

                    // Auto dismiss delay
                    HStack {
                        Text("Auto Dismiss:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Spacer()

                        Picker("", selection: $state.translationDismissSeconds) {
                            Text("Never (Default)").tag(0)
                            Text("5 seconds").tag(5)
                            Text("10 seconds").tag(10)
                            Text("15 seconds").tag(15)
                            Text("20 seconds").tag(20)
                            Text("30 seconds").tag(30)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.mini)
                    }

                    // Window Opacity
                    HStack {
                        Text("Window Opacity:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Button("Preview") {
                            TranslationHudController.shared.show(
                                original: "Teams Wake dynamic sizing and transparency preview.",
                                translated: "Teams Wake dynamically adapts HUD size with frosted glass preview.",
                                direction: "EN ➔ ZH",
                                provider: state.translationProvider.displayName,
                                targetPid: 0
                            )
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9.5))
                        .foregroundColor(.accentColor)

                        Spacer()

                        Slider(
                            value: $state.hudOpacity,
                            in: 0.3...1.0,
                            step: 0.05
                        )
                        .frame(width: 80)
                        .tint(.accentColor)

                        Text("\(Int(state.hudOpacity * 100))%")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
                .padding(.top, 2)

                Text("Select text in any app, then press \(state.translationShortcut.label) to translate and replace/copy")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.top, 1)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        )
    }

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Activity Logs")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                Spacer()

                if !state.logs.isEmpty {
                    Button(isLogsCopied ? "Copied" : "Copy All") {
                        let text = state.logs.map { $0.formattedText }.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.declareTypes([.string], owner: nil)
                        NSPasteboard.general.setString(text, forType: .string)
                        isLogsCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            isLogsCopied = false
                        }
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .foregroundColor(.secondary)
                }

                Button("Clear") {
                    state.clearLogs()
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .foregroundColor(.secondary)
            }

            LogTextView(logs: state.logs)
                .frame(height: 110)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                )
        }
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0"
        let commit = Bundle.main.infoDictionary?["GitCommit"] as? String ?? ""
        if !commit.isEmpty {
            return "v\(version) (\(commit))"
        }
        return "v\(version)"
    }

    private var commitDetailTooltip: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0"
        let commit = Bundle.main.infoDictionary?["GitCommit"] as? String ?? ""
        let date = Bundle.main.infoDictionary?["GitCommitDate"] as? String ?? ""
        let msg = Bundle.main.infoDictionary?["GitCommitMessage"] as? String ?? ""

        var lines: [String] = ["Teams Wake v\(version)"]
        if !commit.isEmpty {
            var commitLine = "Commit: \(commit)"
            if !date.isEmpty {
                commitLine += " (\(date))"
            }
            lines.append(commitLine)
        }
        if !msg.isEmpty {
            lines.append("Message: \(msg)")
        }
        lines.append("Click to copy version details")
        return lines.joined(separator: "\n")
    }

    private var bottomActions: some View {
        HStack {
            Button(action: {
                let msg = Bundle.main.infoDictionary?["GitCommitMessage"] as? String ?? ""
                let textToCopy = "\(appVersionString)\(msg.isEmpty ? "" : " - " + msg)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(textToCopy, forType: .string)
                isVersionCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    isVersionCopied = false
                }
            }) {
                HStack(spacing: 4) {
                    Text(isVersionCopied ? "Copied!" : appVersionString)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(isVersionCopied ? .green : .secondary.opacity(0.85))
                }
            }
            .buttonStyle(.plain)
            .help(commitDetailTooltip)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .font(.system(size: 11))
            .buttonStyle(.borderless)
            .foregroundColor(.red)
        }
    }
}

/// Visual effect blur view
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        if cornerRadius > 0 {
            view.wantsLayer = true
            view.layer?.cornerRadius = cornerRadius
            view.layer?.masksToBounds = true
        }
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        if cornerRadius > 0 {
            nsView.layer?.cornerRadius = cornerRadius
            nsView.layer?.masksToBounds = true
        }
    }
}

/// Native macOS selectable and scrollable log text view with multi-line mouse selection
struct LogTextView: NSViewRepresentable {
    let logs: [LogItem]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.lineFragmentPadding = 2
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        render(into: textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        render(into: textView)
    }

    private func render(into textView: NSTextView) {
        if logs.isEmpty {
            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .center
            let emptyAttr = NSAttributedString(
                string: "\nNo logs yet",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: pStyle
                ]
            )
            textView.textStorage?.setAttributedString(emptyAttr)
            return
        }

        let fullAttr = NSMutableAttributedString()
        for (idx, log) in logs.enumerated() {
            let pStyle = NSMutableParagraphStyle()
            pStyle.firstLineHeadIndent = 0
            pStyle.headIndent = 0
            pStyle.lineSpacing = 1.5
            pStyle.paragraphSpacing = 5

            let isLast = (idx == logs.count - 1)
            let rawText = "\(log.formattedText)\(isLast ? "" : "\n")"
            let line = NSMutableAttributedString(
                string: rawText,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: pStyle,
                    .kern: -0.25
                ]
            )

            // Compress word spacing: apply compact font size to space characters
            let nsString = rawText as NSString
            var searchRange = NSRange(location: 0, length: nsString.length)
            while searchRange.location < nsString.length {
                let spaceRange = nsString.range(of: " ", options: [], range: searchRange)
                if spaceRange.location == NSNotFound { break }
                line.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 5.5, weight: .regular), range: spaceRange)
                let nextLoc = spaceRange.location + spaceRange.length
                searchRange = NSRange(location: nextLoc, length: nsString.length - nextLoc)
            }

            fullAttr.append(line)
        }

        if textView.textStorage?.string != fullAttr.string {
            let range = textView.selectedRange()
            textView.textStorage?.setAttributedString(fullAttr)
            if range.location + range.length <= fullAttr.length {
                textView.setSelectedRange(range)
            }
        }
    }
}
