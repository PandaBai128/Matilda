import AppKit
import SwiftUI

@MainActor
final class CodexUsageSettingsWindowManager {
    private let usageMonitor: CodexUsageMonitor
    private let usageSettings: CodexUsageSettings
    private var window: NSPanel?

    init(usageMonitor: CodexUsageMonitor, usageSettings: CodexUsageSettings) {
        self.usageMonitor = usageMonitor
        self.usageSettings = usageSettings
    }

    func showWindow() {
        if window == nil {
            createWindow()
            window?.center()
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow() {
        let settingsView = CodexUsageSettingsView(
            usageMonitor: usageMonitor,
            usageSettings: usageSettings
        )
        .frame(minWidth: 430, minHeight: 600)

        let hostingView = NSHostingView(rootView: settingsView)
        let settingsWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        settingsWindow.title = "Codex Usage"
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.titleVisibility = .hidden
        settingsWindow.isFloatingPanel = true
        settingsWindow.level = .floating
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        settingsWindow.minSize = NSSize(width: 430, height: 600)
        settingsWindow.contentView = hostingView
        window = settingsWindow
    }
}
