import Foundation
import Combine

/// Watches Teams notifications and forwards them to the phone via Bark when they stay unread.
///
/// Policy: new notifications are queued. If the Teams Dock badge is cleared the queue is dropped;
/// if the badge is still present once the oldest queued message is older than `delayMinutes`,
/// the whole queue is merged into a single push.
@MainActor
public final class TeamsPushMonitor: ObservableObject {
    public static let shared = TeamsPushMonitor()

    private let defaults = UserDefaults.standard
    private let keyEnabled = "teams_push_enabled"
    private let keyDelay = "teams_push_delay_minutes"
    private let keyServer = "teams_push_bark_server"
    private let keyCursor = "teams_push_last_rec_id"
    // Stored in UserDefaults rather than the Keychain: the ad-hoc signature changes on every
    // build, which would otherwise trigger a Keychain password prompt after each update.
    private let keyDeviceKey = "teams_push_bark_device_key"
    private let keyAESKey = "teams_push_bark_aes_key"

    private static let pollInterval: TimeInterval = 5
    private static let retryInterval: TimeInterval = 60
    private static let maxLinesPerPush = 10

    @Published public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: keyEnabled)
            isEnabled ? start() : stop()
        }
    }
    @Published public var delayMinutes: Int {
        didSet { defaults.set(delayMinutes, forKey: keyDelay) }
    }
    @Published public var serverURL: String {
        didSet { defaults.set(serverURL, forKey: keyServer) }
    }
    @Published public var deviceKey: String {
        didSet { defaults.set(deviceKey, forKey: keyDeviceKey) }
    }
    @Published public var encryptionKey: String {
        didSet { defaults.set(encryptionKey, forKey: keyAESKey) }
    }

    @Published public private(set) var databaseError: String?
    @Published public private(set) var badge: TeamsBadgeReader.Result = .unavailable
    @Published public private(set) var pendingCount = 0
    @Published public private(set) var lastPushAt: Date?
    @Published public private(set) var isSendingTest = false

    private var pending: [TeamsMessage] = []
    private var timer: Timer?
    private var isTicking = false
    private var lastFailureAt: Date?
    private var lastBadgeCount: Int?

    private var cursor: Int64 {
        get { Int64(defaults.integer(forKey: keyCursor)) }
        set { defaults.set(Int(newValue), forKey: keyCursor) }
    }

    private var barkConfig: BarkConfig {
        BarkConfig(serverURL: serverURL, deviceKey: deviceKey, encryptionKey: encryptionKey)
    }

    private init() {
        isEnabled = defaults.bool(forKey: keyEnabled)
        let savedDelay = defaults.integer(forKey: keyDelay)
        delayMinutes = savedDelay > 0 ? savedDelay : 3
        serverURL = defaults.string(forKey: keyServer) ?? "https://bark.linrol.eu.org"
        deviceKey = defaults.string(forKey: keyDeviceKey) ?? ""
        encryptionKey = defaults.string(forKey: keyAESKey) ?? ""
    }

    // MARK: - Lifecycle

    public func start() {
        guard isEnabled, timer == nil else { return }
        // Skip notification history: only messages arriving after enabling are forwarded.
        do {
            cursor = try TeamsNotificationSource.shared.latestRecordId()
            databaseError = nil
        } catch {
            databaseError = error.localizedDescription
            log(error.localizedDescription, .error)
        }
        pending.removeAll()
        pendingCount = 0
        lastBadgeCount = TeamsBadgeReader.read().unreadCount
        log("Teams → Bark forwarding started (delay \(delayMinutes) min)", .success)

        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        pending.removeAll()
        pendingCount = 0
        log("Teams → Bark forwarding stopped", .warning)
    }

    // MARK: - Actions

    public func sendTest() {
        isSendingTest = true
        Task {
            defer { isSendingTest = false }
            do {
                try await BarkPushProvider.send(
                    title: "TeamsWake",
                    body: "Test push \(barkConfig.isEncrypted ? "(AES encrypted)" : "(plaintext)") ✅",
                    config: barkConfig
                )
                log("Bark test push sent", .success)
            } catch {
                log("Bark test push failed: \(error.localizedDescription)", .error)
            }
        }
    }

    // MARK: - Polling

    private func tick() async {
        guard isEnabled, !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        let after = cursor
        let result = await Task.detached(priority: .utility) {
            Result { try TeamsNotificationSource.shared.messages(after: after) }
        }.value

        switch result {
        case .success(let messages):
            if databaseError != nil {
                databaseError = nil
                log("Notification database readable again", .success)
            }
            if let last = messages.last {
                cursor = last.recId
                pending.append(contentsOf: messages)
            }
        case .failure(let error):
            if databaseError != error.localizedDescription {
                databaseError = error.localizedDescription
                log(error.localizedDescription, .error)
            }
        }

        badge = TeamsBadgeReader.read()
        let current = badge.unreadCount
        let previous = lastBadgeCount
        if current != nil { lastBadgeCount = current }

        // A decreasing badge means the user is reading on the desktop, so queued messages
        // are considered seen. Increases are just new messages; unknown readings are ignored.
        let userRead = current != nil && previous != nil && current! < previous!
        if userRead || current == 0 {
            if !pending.isEmpty {
                let reason = userRead ? "badge \(previous!) → \(current!)" : "no unread"
                log("Teams activity on desktop (\(reason)), skipped \(pending.count) pending message(s)", .info)
            }
            pending.removeAll()
        } else if let oldest = pending.first,
                  Date().timeIntervalSince(oldest.date) >= Double(delayMinutes * 60),
                  lastFailureAt.map({ Date().timeIntervalSince($0) >= Self.retryInterval }) ?? true {
            await flush()
        }
        pendingCount = pending.count
    }

    private func flush() async {
        let batch = pending
        let title: String
        if case .count(let unread) = badge {
            title = "Teams · \(unread) unread"
        } else {
            title = "Teams · \(batch.count) new message\(batch.count == 1 ? "" : "s")"
        }
        var lines = batch.suffix(Self.maxLinesPerPush).map(\.displayLine)
        if batch.count > Self.maxLinesPerPush {
            lines.insert("… \(batch.count - Self.maxLinesPerPush) earlier message(s)", at: 0)
        }

        do {
            try await BarkPushProvider.send(title: title, body: lines.joined(separator: "\n"), config: barkConfig)
            pending.removeAll { message in batch.contains { $0.recId == message.recId } }
            lastPushAt = Date()
            lastFailureAt = nil
            log("Pushed \(batch.count) Teams message(s) to Bark", .success)
        } catch {
            lastFailureAt = Date()
            log("Bark push failed, retry in \(Int(Self.retryInterval))s: \(error.localizedDescription)", .error)
        }
    }

    private func log(_ message: String, _ type: LogType) {
        AppState.shared.addLog(message: "[Notify] \(message)", type: type)
    }
}
