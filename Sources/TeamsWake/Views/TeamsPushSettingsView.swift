import SwiftUI
import AppKit

/// Settings card for forwarding unread Teams messages to the phone via Bark.
struct TeamsPushSettingsView: View {
    @ObservedObject private var monitor = TeamsPushMonitor.shared
    @State private var isExpanded = false
    @State private var isAESKeyCopied = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
                Text("Phone Push (Bark)")
                    .font(.system(size: 12, weight: .medium))

                Spacer()

                Toggle("", isOn: $monitor.isEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                    .labelsHidden()
                    .controlSize(.mini)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            if monitor.isEnabled {
                statusLine
            }

            if monitor.databaseError != nil {
                fullDiskAccessBanner
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Push if still unread after")
                            .font(.system(size: 11))
                        Spacer()
                        Text("\(monitor.delayMinutes) min")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Slider(
                        value: Binding(
                            get: { Double(monitor.delayMinutes) },
                            set: { monitor.delayMinutes = Int($0.rounded()) }
                        ),
                        in: 1...30,
                        step: 1
                    )
                    .controlSize(.mini)

                    field("Server", text: $monitor.serverURL, prompt: "https://bark.linrol.eu.org")
                    field("Device Key", text: $monitor.deviceKey, prompt: "Bark device key")
                    HStack(spacing: 4) {
                        field("AES Key", text: $monitor.encryptionKey, prompt: "32 chars (AES-256-CBC)")
                        iconButton(
                            "arrow.triangle.2.circlepath",
                            help: "Generate a new 32-char key and copy it"
                        ) {
                            monitor.encryptionKey = BarkPushProvider.generateEncryptionKey()
                            copyAESKey()
                        }
                        iconButton(isAESKeyCopied ? "checkmark" : "doc.on.doc", help: "Copy key") {
                            copyAESKey()
                        }
                        .disabled(monitor.encryptionKey.isEmpty)
                    }

                    HStack {
                        Button(monitor.isSendingTest ? "Sending…" : "Send Test Push") {
                            monitor.sendTest()
                        }
                        .controlSize(.small)
                        .disabled(monitor.isSendingTest || monitor.deviceKey.isEmpty)

                        Spacer()

                        Button("Full Disk Access…") { openFullDiskAccess() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        )
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Text(badgeText)
            Text("·")
            Text("\(monitor.pendingCount) pending")
            if let last = monitor.lastPushAt {
                Text("·")
                Text("last push \(last.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
    }

    private var badgeText: String {
        switch monitor.badge {
        case .count(let n): return "Badge \(n)"
        case .none: return "No unread"
        case .unavailable:
            return AXIsProcessTrusted() ? "Badge unknown" : "Badge unknown (Accessibility not granted)"
        }
    }

    private var fullDiskAccessBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("Full Disk Access is required to read Teams notifications.")
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Open") { openFullDiskAccess() }
                .controlSize(.mini)
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 70, alignment: .leading)
            TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .controlSize(.small)
        }
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func copyAESKey() {
        guard !monitor.encryptionKey.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(monitor.encryptionKey, forType: .string)
        isAESKeyCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isAESKeyCopied = false }
    }

    private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
