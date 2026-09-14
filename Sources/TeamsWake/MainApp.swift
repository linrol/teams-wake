import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory app: no Dock icon, stays in the menu bar as a status item
        NSApp.setActivationPolicy(.accessory)
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
            let iconName = appState.isActive ? "bolt.circle.fill" : "bolt.circle"
            Image(systemName: iconName)
        }
        .menuBarExtraStyle(.window)
    }
}
