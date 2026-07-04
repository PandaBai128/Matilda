//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    private var modifierPollingTimer: Timer?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else {
            clickyDebugLog("global-monitor already-running")
            return
        }
        clickyDebugLog("global-monitor start-requested")

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            clickyDebugLog("global-monitor tap-create-failed")
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            clickyDebugLog("global-monitor run-loop-source-failed")
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
        startModifierPollingFallback()
        clickyDebugLog("global-monitor started")
    }

    func stop() {
        if globalEventTap != nil || globalEventTapRunLoopSource != nil {
            clickyDebugLog("global-monitor stopped")
        }
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }

        modifierPollingTimer?.invalidate()
        modifierPollingTimer = nil
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            clickyDebugLog("global-monitor tap-disabled eventType=\(eventType.rawValue) re-enabling")
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            clickyDebugLog("global-monitor transition=pressed keyCode=\(eventKeyCode) flags=\(event.flags.rawValue)")
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            clickyDebugLog("global-monitor transition=released keyCode=\(eventKeyCode) flags=\(event.flags.rawValue)")
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }

    private func startModifierPollingFallback() {
        modifierPollingTimer?.invalidate()
        modifierPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.pollModifierShortcutState()
        }
        if let modifierPollingTimer {
            RunLoop.main.add(modifierPollingTimer, forMode: .common)
        }
    }

    private func pollModifierShortcutState() {
        guard BuddyPushToTalkShortcut.currentShortcutOption == .controlOption else { return }

        let flags = CGEventSource.flagsState(.combinedSessionState)
        let isShortcutPressed = flags.contains(.maskControl) && flags.contains(.maskAlternate)

        if isShortcutPressed && !isShortcutCurrentlyPressed {
            isShortcutCurrentlyPressed = true
            clickyDebugLog("global-monitor polling-transition=pressed flags=\(flags.rawValue)")
            shortcutTransitionPublisher.send(.pressed)
        }

        if !isShortcutPressed && isShortcutCurrentlyPressed {
            isShortcutCurrentlyPressed = false
            clickyDebugLog("global-monitor polling-transition=released flags=\(flags.rawValue)")
            shortcutTransitionPublisher.send(.released)
        }
    }
}
