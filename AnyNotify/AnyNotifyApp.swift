import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = MonitorStore()
    private var reminderPanelController: CompletionReminderPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-UITestMode")
        NSApp.setActivationPolicy(isUITesting ? .regular : .accessory)
        if isUITesting {
            NSApp.activate(ignoringOtherApps: true)
        }
        _ = DesktopNotificationService.shared
        reminderPanelController = CompletionReminderPanelController(store: store)
        store.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            store.handle(url: url)
        }
    }
}

@main
struct AnyNotifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("AnyNotify", systemImage: "bell.and.waves.left.and.right.fill") {
            MenuBarView()
                .environmentObject(appDelegate.store)
        }
    }
}
