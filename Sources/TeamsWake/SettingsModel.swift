import Foundation
import Combine
import SwaprTransKit

public enum LogType: String, Codable {
    case info
    case success
    case warning
    case error
}

public struct LogItem: Identifiable, Equatable {
    public let id = UUID()
    public let date: Date
    public let message: String
    public let type: LogType

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss"
        return df
    }()

    public var formattedText: String {
        let timeStr = Self.timeFormatter.string(from: date)
        if message.range(of: #"^\[(?:\d{4}-)?\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]"#, options: .regularExpression) != nil {
            return message
        }
        return "[\(timeStr)] \(message)"
    }

    public init(message: String, type: LogType = .info) {
        self.date = Date()
        self.message = message
        self.type = type
    }
}

public struct ScheduleItem: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var startTime: String // "HH:mm"
    public var endTime: String   // "HH:mm"
    public var days: [Int]       // 1: Mon, 2: Tue, ..., 5: Fri, 6: Sat, 0: Sun

    public init(id: String = UUID().uuidString, name: String, enabled: Bool = true, startTime: String, endTime: String, days: [Int]) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.startTime = startTime
        self.endTime = endTime
        self.days = days
    }
}

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    private let defaults = UserDefaults.standard
    private let keyInterval = "teams_wake_interval"
    private let keyScheduleEnabled = "teams_wake_schedule_enabled"
    private let keySchedules = "teams_wake_schedules"
    @Published public var isActive: Bool = false {
        didSet {
            handleActiveStateChanged()
        }
    }

    @Published public var intervalMinutes: Int {
        didSet {
            defaults.set(intervalMinutes, forKey: keyInterval)
            restartTimerIfNeeded()
        }
    }

    @Published public var scheduleEnabled: Bool {
        didSet {
            defaults.set(scheduleEnabled, forKey: keyScheduleEnabled)
            evaluateSchedules()
        }
    }

    @Published public var schedules: [ScheduleItem] {
        didSet {
            saveSchedules()
            evaluateSchedules()
        }
    }

    public var isAutoTranslateActive: Bool {
        get { SwaprTransConfig.shared.isEnabled }
        set { SwaprTransConfig.shared.isEnabled = newValue }
    }

    public var translationProvider: TranslationProvider {
        get { SwaprTransConfig.shared.provider }
        set { SwaprTransConfig.shared.provider = newValue }
    }

    public var translationShortcut: TranslationShortcut {
        get { SwaprTransConfig.shared.shortcut }
        set { SwaprTransConfig.shared.shortcut = newValue }
    }

    public var translationDismissSeconds: Int {
        get { SwaprTransConfig.shared.autoDismissSeconds }
        set { SwaprTransConfig.shared.autoDismissSeconds = newValue }
    }

    public var hudOpacity: Double {
        get { SwaprTransConfig.shared.hudOpacity }
        set { SwaprTransConfig.shared.hudOpacity = newValue }
    }

    @Published public var logs: [LogItem] = []
    @Published public var hasAccessibilityPermission: Bool = false
    @Published public var lastScheduleMatchedName: String? = nil

    private var keepAliveTimer: Timer?
    private var scheduleCheckTimer: Timer?
    private var manualOverride: Bool? = nil

    private init() {
        let savedInterval = defaults.integer(forKey: keyInterval)
        self.intervalMinutes = savedInterval > 0 ? savedInterval : 3

        self.scheduleEnabled = defaults.bool(forKey: keyScheduleEnabled)

        if let data = defaults.data(forKey: keySchedules),
           let list = try? JSONDecoder().decode([ScheduleItem].self, from: data) {
            self.schedules = list.enumerated().map { index, item in
                var mod = item
                if !mod.name.lowercased().starts(with: "schedule") {
                    mod.name = "Schedule \(index + 1)"
                }
                return mod
            }
        } else {
            self.schedules = [
                ScheduleItem(id: "schedule_1", name: "Schedule 1", startTime: "09:00", endTime: "12:00", days: [1, 2, 3, 4, 5]),
                ScheduleItem(id: "schedule_2", name: "Schedule 2", startTime: "13:30", endTime: "18:00", days: [1, 2, 3, 4, 5])
            ]
        }

        checkPermission()
        setupScheduleMonitoring()
        addLog(message: "Teams Wake native daemon ready", type: .info)

        // Configure SwaprTrans integration
        SwaprTransConfig.shared.ignoredAppNameKeywords.insert("teams")
        SwaprTransConfig.shared.logHandler = { [weak self] message, level in
            let type: LogType
            switch level {
            case .info: type = .info
            case .success: type = .success
            case .warning: type = .warning
            case .error: type = .error
            }
            self?.addLog(message: message, type: type)
        }
    }

    public func toggleAutoTranslate() {
        SwaprTransConfig.shared.toggleEnabled()
    }

    public func addLog(message: String, type: LogType = .info) {
        let item = LogItem(message: message, type: type)
        logs.insert(item, at: 0)
        if logs.count > 60 {
            logs.removeLast()
        }
    }

    public func clearLogs() {
        logs.removeAll()
    }

    public func checkPermission() {
        hasAccessibilityPermission = KeepAliveEngine.shared.checkAccessibilityPermission(prompt: false)
    }

    public func requestPermission() {
        _ = KeepAliveEngine.shared.checkAccessibilityPermission(prompt: true)
        checkPermission()
    }

    public func toggleActive(manual: Bool = true) {
        if !isActive {
            checkPermission()
            if !hasAccessibilityPermission {
                addLog(message: "Accessibility permission required to trigger hardware micro-movements", type: .error)
                requestPermission()
                return
            }
        }

        if manual && scheduleEnabled {
            manualOverride = !isActive
            addLog(message: "[Schedule] Manual state switched to: \(!isActive ? "ON" : "OFF"), auto schedule will resume on next interval switch", type: .info)
        }

        isActive.toggle()
    }

    private func handleActiveStateChanged() {
        if isActive {
            addLog(message: "System keep-alive started (Interval: \(intervalMinutes) min)", type: .success)
            startKeepAliveTimer()
            // Run initial keep-alive trigger upon startup
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if isActive {
                    runKeepAliveIteration()
                }
            }
        } else {
            addLog(message: "System keep-alive stopped", type: .warning)
            stopKeepAliveTimer()
        }
    }

    private func startKeepAliveTimer() {
        stopKeepAliveTimer()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: Double(intervalMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runKeepAliveIteration()
            }
        }
    }

    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    private func restartTimerIfNeeded() {
        if isActive {
            startKeepAliveTimer()
            addLog(message: "Keep-alive interval updated to \(intervalMinutes) min", type: .info)
        }
    }

    public func runKeepAliveIteration() {
        guard isActive else { return }

        let idleSeconds = KeepAliveEngine.shared.getSystemIdleTime()
        _ = KeepAliveEngine.shared.performMicroWiggle()

        // Wait 100ms for driver and IOHIDSystem registry refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            let afterIdle = KeepAliveEngine.shared.getSystemIdleTime()
            self.addLog(
                message: "Hardware clock reset successful: \(String(format: "%.1f", idleSeconds))s ➔ \(String(format: "%.2f", afterIdle))s (✔ Reset)",
                type: .success
            )
        }
    }

    // MARK: - Schedule Logic
    private func setupScheduleMonitoring() {
        scheduleCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateSchedules()
            }
        }
    }

    public func evaluateSchedules() {
        guard scheduleEnabled else {
            lastScheduleMatchedName = nil
            manualOverride = nil
            return
        }

        let now = Date()
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: now)
        // Calendar weekday: 1 is Sunday, 2 is Monday, ..., 7 is Saturday
        let mappedDay = (weekday == 1) ? 0 : (weekday - 1)

        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let currentMinutes = hour * 60 + minute

        var matchedSchedule: ScheduleItem? = nil

        for item in schedules where item.enabled {
            guard item.days.contains(mappedDay) else { continue }
            let sParts = item.startTime.split(separator: ":").compactMap { Int($0) }
            let eParts = item.endTime.split(separator: ":").compactMap { Int($0) }
            guard sParts.count == 2, eParts.count == 2 else { continue }

            let sMins = sParts[0] * 60 + sParts[1]
            let eMins = eParts[0] * 60 + eParts[1]

            if sMins <= eMins {
                if currentMinutes >= sMins && currentMinutes < eMins {
                    matchedSchedule = item
                    break
                }
            } else {
                // Spans midnight
                if currentMinutes >= sMins || currentMinutes < eMins {
                    matchedSchedule = item
                    break
                }
            }
        }

        let shouldBeActive = (matchedSchedule != nil)

        // Boundary switch detection
        if lastScheduleMatchedName != matchedSchedule?.name {
            manualOverride = nil
            lastScheduleMatchedName = matchedSchedule?.name

            if shouldBeActive {
                if !isActive {
                    addLog(message: "[Schedule] Entered \"\(matchedSchedule?.name ?? "Schedule")\", auto-activating keep-alive", type: .success)
                    isActive = true
                }
            } else {
                if isActive {
                    addLog(message: "[Schedule] Scheduled interval ended, auto-stopping keep-alive", type: .info)
                    isActive = false
                }
            }
        } else {
            // Keep consistent within the same interval if no manual override
            if manualOverride == nil {
                if shouldBeActive && !isActive {
                    isActive = true
                } else if !shouldBeActive && isActive {
                    isActive = false
                }
            }
        }
    }

    public func addSchedule(name: String, startTime: String, endTime: String, days: [Int] = [1, 2, 3, 4, 5]) {
        let item = ScheduleItem(name: name, enabled: true, startTime: startTime, endTime: endTime, days: days)
        schedules.append(item)
        addLog(message: "Added keep-alive schedule: \(name) (\(startTime) - \(endTime))", type: .info)
    }

    public func removeSchedule(id: String) {
        if let idx = schedules.firstIndex(where: { $0.id == id }) {
            let name = schedules[idx].name
            schedules.remove(at: idx)
            addLog(message: "Deleted keep-alive schedule: \(name)", type: .info)
        }
    }

    private func saveSchedules() {
        if let data = try? JSONEncoder().encode(schedules) {
            defaults.set(data, forKey: keySchedules)
        }
    }
}
