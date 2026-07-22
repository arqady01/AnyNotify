import AppKit
import Combine
import SwiftUI

@MainActor
final class CompletionReminderPanelController {
    private static let frameAutosaveName = "CompletionReminderPanel"
    private static let panelSize = NSSize(width: 300, height: 176)

    private let panel: NSPanel
    private var reminderCancellable: AnyCancellable?
    private var hasInitialPosition = false

    init(store: MonitorStore) {
        let contentView = CompletionReminderView()
            .environmentObject(store)
        let hostingController = NSHostingController(rootView: contentView)

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "任务完成提醒"
        panel.contentViewController = hostingController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        hasInitialPosition = panel.setFrameUsingName(Self.frameAutosaveName)
        if hasInitialPosition {
            var frame = panel.frame
            let topEdge = frame.maxY
            frame.size = Self.panelSize
            frame.origin.y = topEdge - frame.height
            panel.setFrame(frame, display: false)
        }
        panel.setFrameAutosaveName(Self.frameAutosaveName)

        reminderCancellable = store.$completionReminder
            .sink { [weak self] reminder in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if reminder == nil {
                        hide()
                    } else {
                        show()
                    }
                }
            }
    }

    private func hide() {
        panel.orderOut(nil)
    }

    private func show() {
        if !hasInitialPosition {
            positionNearTopRight()
            hasInitialPosition = true
        }
        panel.orderFrontRegardless()
    }

    private func positionNearTopRight() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.maxX - panel.frame.width - 24,
            y: visibleFrame.maxY - panel.frame.height - 24
        )
        panel.setFrameOrigin(origin)
    }
}
