//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
    static let clickyShowVoiceSettings = Notification.Name("clickyShowVoiceSettings")
    static let clickyShowAppearanceSettings = Notification.Name("clickyShowAppearanceSettings")
    static let clickyShowCodexUsageSettings = Notification.Name("clickyShowCodexUsageSettings")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class PassthroughStatusHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var statusItemHostingView: NSView?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var showVoiceSettingsObserver: NSObjectProtocol?
    private var showAppearanceSettingsObserver: NSObjectProtocol?
    private var showCodexUsageSettingsObserver: NSObjectProtocol?
    private var statusItemSubscriptions = Set<AnyCancellable>()

    private let companionManager: CompanionManager
    private let usageMonitor: CodexUsageMonitor
    private let usageSettings: CodexUsageSettings
    private let voiceSettingsWindowManager: VoiceSettingsWindowManager
    private let appearanceSettingsWindowManager: AppearanceSettingsWindowManager
    private let codexUsageSettingsWindowManager: CodexUsageSettingsWindowManager
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    init(
        companionManager: CompanionManager,
        usageMonitor: CodexUsageMonitor,
        usageSettings: CodexUsageSettings
    ) {
        self.companionManager = companionManager
        self.usageMonitor = usageMonitor
        self.usageSettings = usageSettings
        self.voiceSettingsWindowManager = VoiceSettingsWindowManager(companionManager: companionManager)
        self.appearanceSettingsWindowManager = AppearanceSettingsWindowManager(companionManager: companionManager)
        self.codexUsageSettingsWindowManager = CodexUsageSettingsWindowManager(
            usageMonitor: usageMonitor,
            usageSettings: usageSettings
        )
        super.init()
        createStatusItem()
        observeStatusItemPresentation()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }

        showVoiceSettingsObserver = NotificationCenter.default.addObserver(
            forName: .clickyShowVoiceSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
            self?.voiceSettingsWindowManager.showWindow()
        }

        showAppearanceSettingsObserver = NotificationCenter.default.addObserver(
            forName: .clickyShowAppearanceSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hidePanel()
                self?.appearanceSettingsWindowManager.showWindow()
            }
        }

        showCodexUsageSettingsObserver = NotificationCenter.default.addObserver(
            forName: .clickyShowCodexUsageSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hidePanel()
                self?.codexUsageSettingsWindowManager.showWindow()
            }
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showVoiceSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showAppearanceSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showCodexUsageSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.action = #selector(statusItemClicked)
        button.target = self
        refreshStatusItemPresentation()
    }

    private func observeStatusItemPresentation() {
        Publishers.MergeMany(
            usageMonitor.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            usageSettings.$isMenuBarUsageVisible.map { _ in () }.eraseToAnyPublisher(),
            usageSettings.$isWeeklyLimitVisible.map { _ in () }.eraseToAnyPublisher(),
            usageSettings.$isFiveHourLimitVisible.map { _ in () }.eraseToAnyPublisher(),
            usageSettings.$showsResetCountdownWhenExhausted.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            self?.refreshStatusItemPresentation()
        }
        .store(in: &statusItemSubscriptions)
    }

    private func refreshStatusItemPresentation() {
        guard let statusItem, let button = statusItem.button else { return }

        let visibleLimitCount = menuBarVisibleLimitCount
        switch visibleLimitCount {
        case 1:
            statusItem.length = 76
        case 2:
            statusItem.length = 126
        default:
            statusItem.length = NSStatusItem.squareLength
        }

        button.image = nil
        statusItemHostingView?.removeFromSuperview()

        let statusContent = CodexUsageMenuBarContent(
            usageMonitor: usageMonitor,
            usageSettings: usageSettings
        )
        let hostingView = PassthroughStatusHostingView(rootView: statusContent)
        hostingView.frame = button.bounds
        hostingView.autoresizingMask = [.width, .height]
        button.addSubview(hostingView)
        statusItemHostingView = hostingView
    }

    private var menuBarVisibleLimitCount: Int {
        guard usageSettings.isMenuBarUsageVisible,
              let snapshot = usageMonitor.snapshot
        else {
            return 0
        }

        var visibleLimitCount = 0
        if usageSettings.isWeeklyLimitVisible, snapshot.weeklyLimit != nil {
            visibleLimitCount += 1
        }
        if usageSettings.isFiveHourLimitVisible, snapshot.fiveHourLimit != nil {
            visibleLimitCount += 1
        }
        return visibleLimitCount
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        usageMonitor.noteUserInteraction()
        if usageMonitor.isSnapshotStale() {
            Task { await usageMonitor.refresh() }
        }

        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        // Horizontally center the panel beneath the status item icon
        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus, so do not dismiss during permission setup.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}

private struct CodexUsageMenuBarContent: View {
    @ObservedObject var usageMonitor: CodexUsageMonitor
    @ObservedObject var usageSettings: CodexUsageSettings

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timelineContext in
            HStack(spacing: 7) {
                Image("ZhuangzhuangMenuIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)

                if usageSettings.isMenuBarUsageVisible,
                   let snapshot = usageMonitor.snapshot {
                    if usageSettings.isWeeklyLimitVisible,
                       let weeklyLimit = snapshot.weeklyLimit {
                        usageColumn(
                            quotaWindow: weeklyLimit,
                            label: "WEEK",
                            currentDate: timelineContext.date
                        )
                    }

                    if usageSettings.isFiveHourLimitVisible,
                       let fiveHourLimit = snapshot.fiveHourLimit {
                        usageColumn(
                            quotaWindow: fiveHourLimit,
                            label: "5 HR",
                            currentDate: timelineContext.date
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func usageColumn(
        quotaWindow: CodexQuotaWindow,
        label: String,
        currentDate: Date
    ) -> some View {
        VStack(spacing: -1) {
            Text(CodexUsageFormatting.menuValue(
                for: quotaWindow,
                showsResetCountdownWhenExhausted: usageSettings.showsResetCountdownWhenExhausted,
                currentDate: currentDate
            ))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            Text(label)
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .tracking(0.35)
        }
        .foregroundStyle(Color.primary)
        .frame(minWidth: 34)
    }
}
