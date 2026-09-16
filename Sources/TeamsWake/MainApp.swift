import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory app: no Dock icon, stays in the menu bar as a status item
        NSApp.setActivationPolicy(.accessory)
        UpdateManager.shared.startBackgroundCheck()
    }
}

@main
struct TeamsWakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopup()
        } label: {
            if appState.isActive {
                Image(systemName: "bolt.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.green)
            } else {
                Image(systemName: "bolt.circle")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
