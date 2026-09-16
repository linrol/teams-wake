import Foundation
import AppKit
import SwiftUI

public struct RemoteReleaseInfo: Codable {
    public let version: String
    public let commit: String
    public let date: String?
    public let message: String?
    public let dmgUrl: String
}

@MainActor
public final class UpdateManager: NSObject, ObservableObject {
    public static let shared = UpdateManager()

    @Published public var isChecking: Bool = false
    @Published public var hasUpdate: Bool = false
    @Published public var isDownloading: Bool = false
    @Published public var downloadProgress: Double = 0.0
    @Published public var updateError: String? = nil
    @Published public var remoteInfo: RemoteReleaseInfo? = nil

    private var checkTimer: Timer?
    private var downloadTask: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    private let updateEndpoints: [String] = [
        "https://github.com/linrol/teams-wake/releases/latest/download/version.json",
        "https://raw.githubusercontent.com/linrol/teams-wake/master/version.json"
    ]

    public var localVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0"
    }

    public var localCommit: String {
        Bundle.main.infoDictionary?["GitCommit"] as? String ?? ""
    }

    public var localCommitDate: String {
        Bundle.main.infoDictionary?["GitCommitDate"] as? String ?? ""
    }

    private override init() {
        super.init()
    }

    /// Schedule background update check on app launch and periodic intervals
    public func startBackgroundCheck() {
        // Initial check 4 seconds after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            Task { @MainActor in
                await self?.checkForUpdates(silent: true)
            }
        }

        // Periodic check every 4 hours
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForUpdates(silent: true)
            }
        }
    }

    /// Check remote repositories for newer version or commit
    public func checkForUpdates(silent: Bool = false) async {
        guard !isChecking, !isDownloading else { return }
        isChecking = true
        updateError = nil

        defer {
            isChecking = false
        }

        for endpoint in updateEndpoints {
            guard let url = URL(string: endpoint) else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 6.0
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 else {
                    continue
                }

                let decoder = JSONDecoder()
                let info = try decoder.decode(RemoteReleaseInfo.self, from: data)

                // Comparison logic: different version OR different commit
                let isNewerVersion = info.version != self.localVersion
                let isNewerCommit = !self.localCommit.isEmpty && !info.commit.isEmpty && info.commit != self.localCommit

                if isNewerVersion || isNewerCommit {
                    self.remoteInfo = info
                    self.hasUpdate = true
                    AppState.shared.addLog(message: "[Update] New version available: v\(info.version) (\(info.commit))", type: .info)
                } else {
                    self.hasUpdate = false
                    self.remoteInfo = nil
                }
                return
            } catch {
                // Try next endpoint
                continue
            }
        }

        if !silent && !hasUpdate {
            updateError = "Already up to date (v\(localVersion))"
        }
    }

    /// Download latest DMG and perform in-place replacement and restart
    public func downloadAndInstallUpdate() {
        guard let info = remoteInfo, let url = URL(string: info.dmgUrl), !isDownloading else { return }

        isDownloading = true
        downloadProgress = 0.0
        updateError = nil

        let tempDmgPath = "/tmp/TeamsWake_update.dmg"
        try? FileManager.default.removeItem(atPath: tempDmgPath)

        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: url) { [weak self] tempUrl, response, error in
            Task { @MainActor in
                guard let self = self else { return }
                self.isDownloading = false

                if let error = error {
                    self.updateError = "Download failed: \(error.localizedDescription)"
                    return
                }

                guard let tempUrl = tempUrl else {
                    self.updateError = "Download failed: invalid download source"
                    return
                }

                do {
                    try? FileManager.default.removeItem(atPath: tempDmgPath)
                    try FileManager.default.moveItem(at: tempUrl, to: URL(fileURLWithPath: tempDmgPath))
                    self.performAppReplacement()
                } catch {
                    self.updateError = "Failed to save installer: \(error.localizedDescription)"
                }
            }
        }

        // Track download progress
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor in
                self?.downloadProgress = progress.fractionCompleted
            }
        }

        self.downloadTask = task
        task.resume()
    }

    /// Spawn a detached script to mount DMG, replace /Applications/TeamsWake.app and relaunch
    private func performAppReplacement() {
        let scriptPath = "/tmp/teams_wake_updater.sh"
        let scriptContent = """
        #!/bin/bash
        sleep 0.5
        for i in {1..25}; do
            if ! pgrep -x TeamsWake >/dev/null; then break; fi
            sleep 0.2
        done

        TMP_MOUNT="/tmp/TeamsWake_mount_$$"
        mkdir -p "$TMP_MOUNT"
        hdiutil attach "/tmp/TeamsWake_update.dmg" -mountpoint "$TMP_MOUNT" -nobrowse -quiet

        if [ -d "$TMP_MOUNT/TeamsWake.app" ]; then
            rm -rf "/Applications/TeamsWake.app"
            cp -R "$TMP_MOUNT/TeamsWake.app" "/Applications/TeamsWake.app"
            xattr -cr "/Applications/TeamsWake.app"
        fi

        hdiutil detach "$TMP_MOUNT" -quiet 2>/dev/null || true
        rm -rf "$TMP_MOUNT"
        rm -f "/tmp/TeamsWake_update.dmg"
        rm -f "$0"

        open "/Applications/TeamsWake.app"
        """

        do {
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let perms = [FileAttributeKey.posixPermissions: 0o755]
            try FileManager.default.setAttributes(perms, ofItemAtPath: scriptPath)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
            try process.run()

            // Gracefully terminate this application so the updater script can take over
            NSApplication.shared.terminate(nil)
        } catch {
            updateError = "Failed to initiate update: \(error.localizedDescription)"
        }
    }
}
