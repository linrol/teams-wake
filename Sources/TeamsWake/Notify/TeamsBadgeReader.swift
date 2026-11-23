import AppKit
import ApplicationServices

/// Reads the unread badge shown on the Teams Dock icon via the Accessibility API.
public enum TeamsBadgeReader {
    public enum Result: Equatable {
        /// Badge visible with the given count (non-numeric labels such as "•" count as 1).
        case count(Int)
        /// Teams is in the Dock but shows no badge.
        case none
        /// Badge could not be read (no Accessibility permission, Dock or Teams not found).
        case unavailable

        /// Unread count, `0` when no badge, `nil` when unknown.
        public var unreadCount: Int? {
            switch self {
            case .count(let n): return n
            case .none: return 0
            case .unavailable: return nil
            }
        }
    }

    public static func read() -> Result {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return .unavailable
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        for list in children(of: dockElement) where role(of: list) == kAXListRole as String {
            for item in children(of: list) {
                guard let title = stringAttribute(item, kAXTitleAttribute as String),
                      title.localizedCaseInsensitiveContains("Teams") else { continue }
                guard let label = stringAttribute(item, "AXStatusLabel"), !label.isEmpty else {
                    return .none
                }
                let digits = label.filter(\.isNumber)
                return .count(Int(digits) ?? 1)
            }
        }
        return .unavailable
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private static func role(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXRoleAttribute as String)
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
