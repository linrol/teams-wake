import SwiftUI
import AppKit
import KatibKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory app: no Dock icon, stays in the menu bar as a status item
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("TeamsWake MenuBar Daemon")
        ProcessInfo.processInfo.disableSuddenTermination()

        setupStatusItem()
        setupPopover()
        observeAppState()

        UpdateManager.shared.startBackgroundCheck()

        // Forward Katib speech logs to TeamsWake activity logs
        KatibManager.shared.onLog = { message, isError in
            Task { @MainActor in
                AppState.shared.addLog(message: message, type: isError ? .error : .info)
            }
        }
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 500)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuBarPopup())
        self.popover = popover
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            updateStatusItemImage(isActive: AppState.shared.isActive)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
    }

    private func observeAppState() {
        AppState.shared.$isActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.updateStatusItemImage(isActive: isActive)
            }
            .store(in: &cancellables)
    }

    private func updateStatusItemImage(isActive: Bool) {
        guard let button = statusItem?.button else { return }
        if isActive {
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen])
            button.image = NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: "TeamsWake (Active)")?
                .withSymbolConfiguration(config)
        } else {
            button.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "TeamsWake (Inactive)")
        }
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@main
struct TeamsWakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
