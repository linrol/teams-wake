import Foundation

/// Maps the app a push originates from to an icon in `assets/push-icons/`.
/// Bark downloads the icon by URL, so files are served from the repository's raw content
/// through the git.linrol.cn GitHub proxy, which phones can reach without a VPN.
/// Apps without an entry fall back to Bark's default icon.
public enum PushIcons {
    private static let baseURL = "https://git.linrol.cn/https://raw.githubusercontent.com/linrol/teams-wake/master/assets/push-icons/"

    private static let mapping: [String: String] = [
        "Teams": "teams.png",
        "TeamsWake": "teamswake.png"
    ]

    public static func url(for app: String) -> String? {
        mapping[app].map { baseURL + $0 }
    }
}
