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
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.store)
        } label: {
            MenuBarStatusIcon(store: appDelegate.store)
        }
    }
}

private struct MenuBarStatusIcon: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        Image(systemName: store.isMonitoring
              ? "bell.and.waves.left.and.right.fill"
              : "bell.fill")
            .accessibilityLabel(store.isMonitoring ? "AnyNotify，正在监控任务状态" : "AnyNotify，已暂停监控任务状态")
    }
}
