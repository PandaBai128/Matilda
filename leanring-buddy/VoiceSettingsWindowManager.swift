//
//  VoiceSettingsWindowManager.swift
//  leanring-buddy
//
//  Owns the standalone MiniMax voice browser and tuning window.
//

import AppKit
import SwiftUI

@MainActor
final class VoiceSettingsWindowManager {
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
        let voiceSettingsView = VoiceSettingsView(companionManager: companionManager)
            .frame(minWidth: 720, minHeight: 600)

        let hostingView = NSHostingView(rootView: voiceSettingsView)
        let voiceSettingsWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        voiceSettingsWindow.title = "Voice Settings"
        voiceSettingsWindow.titlebarAppearsTransparent = true
        voiceSettingsWindow.titleVisibility = .hidden
        voiceSettingsWindow.isFloatingPanel = true
        voiceSettingsWindow.level = .floating
        voiceSettingsWindow.isReleasedWhenClosed = false
        voiceSettingsWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        voiceSettingsWindow.minSize = NSSize(width: 720, height: 600)
        voiceSettingsWindow.contentView = hostingView
        window = voiceSettingsWindow
    }
}
