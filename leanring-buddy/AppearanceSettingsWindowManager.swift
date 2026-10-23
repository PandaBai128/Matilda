//
//  AppearanceSettingsWindowManager.swift
//  leanring-buddy
//
//  Owns the standalone companion appearance and motion settings window.
//

import AppKit
import SwiftUI

@MainActor
final class AppearanceSettingsWindowManager {
    private let companionManager: CompanionManager
    private var window: NSPanel?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
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
        let appearanceSettingsView = AppearanceSettingsView(companionManager: companionManager)
            .frame(minWidth: 600, minHeight: 650)

        let hostingView = NSHostingView(rootView: appearanceSettingsView)
        let appearanceSettingsWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 740),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        appearanceSettingsWindow.title = "壮壮的外观"
        appearanceSettingsWindow.titlebarAppearsTransparent = true
        appearanceSettingsWindow.titleVisibility = .hidden
        appearanceSettingsWindow.isFloatingPanel = true
        appearanceSettingsWindow.level = .floating
        appearanceSettingsWindow.isReleasedWhenClosed = false
        appearanceSettingsWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        appearanceSettingsWindow.minSize = NSSize(width: 600, height: 650)
        appearanceSettingsWindow.contentView = hostingView
        window = appearanceSettingsWindow
    }
}
