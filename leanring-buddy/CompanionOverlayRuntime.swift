//
//  CompanionOverlayRuntime.swift
//  leanring-buddy
//
//  Shared event-driven runtime for cursor tracking and overlay visibility.
//

import AppKit
import Combine
import Foundation

enum CompanionAnimationCadencePolicy {
    static func framesPerSecond(
        voiceState: CompanionVoiceState,
        navigationMode: BuddyNavigationMode
    ) -> Double? {
        switch navigationMode {
        case .navigatingToTarget:
            return 30
        case .pointingAtTarget:
            return 24
        case .followingCursor:
            break
        }

        switch voiceState {
        case .idle, .responding:
            return nil
        case .listening:
            return 24
        case .processing:
            return 12
        }
    }
}

enum CompanionOverlayGeometry {
    static func localPoint(
        forGlobalScreenPoint screenPoint: CGPoint,
        screenFrame: CGRect
    ) -> CGPoint {
        CGPoint(
            x: screenPoint.x - screenFrame.origin.x,
            y: screenFrame.maxY - screenPoint.y
        )
    }

    static func screenFrame(
        containing globalPoint: CGPoint,
        availableScreenFrames: [CGRect]
    ) -> CGRect? {
        availableScreenFrames.first { $0.contains(globalPoint) }
    }

    static func clampedAvatarDestination(
        beside markerPosition: CGPoint,
        avatarDiameter: CGFloat,
        screenSize: CGSize
    ) -> CGPoint {
        let requestedDestination = CGPoint(
            x: markerPosition.x + max(18, avatarDiameter * 0.82),
            y: markerPosition.y - max(16, avatarDiameter * 0.68)
        )
        let avatarRadius = avatarDiameter / 2
        return CGPoint(
            x: max(avatarRadius, min(requestedDestination.x, screenSize.width - avatarRadius)),
            y: max(avatarRadius, min(requestedDestination.y, screenSize.height - avatarRadius))
        )
    }
}

@MainActor
final class CompanionScheduledAction {
    private var cancellationHandler: (() -> Void)?

    init(cancellationHandler: @escaping () -> Void) {
        self.cancellationHandler = cancellationHandler
    }

    func cancel() {
        cancellationHandler?()
        cancellationHandler = nil
    }
}

@MainActor
final class CompanionAutoHideController {
    typealias Scheduler = (
        _ delaySeconds: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> CompanionScheduledAction

    private let scheduler: Scheduler
    private let visibilityDidChange: (Bool) -> Void
    private var scheduledHideAction: CompanionScheduledAction?
    private var scheduleGeneration = UUID()
    private var isEnabled = false
    private var delaySeconds: TimeInterval = CompanionManager.defaultCompanionAutoHideDelaySeconds
    private var isInteractionActive = false
    private var isFollowingCursor = true

    private(set) var isHidden = false

    init(
        scheduler: @escaping Scheduler = CompanionAutoHideController.liveScheduler,
        visibilityDidChange: @escaping (Bool) -> Void
    ) {
        self.scheduler = scheduler
        self.visibilityDidChange = visibilityDidChange
    }

    func configure(
        isEnabled: Bool,
        delaySeconds: TimeInterval,
        isInteractionActive: Bool,
        isFollowingCursor: Bool
    ) {
        let configurationChanged = self.isEnabled != isEnabled
            || self.delaySeconds != delaySeconds
            || self.isInteractionActive != isInteractionActive
            || self.isFollowingCursor != isFollowingCursor

        self.isEnabled = isEnabled
        self.delaySeconds = delaySeconds
        self.isInteractionActive = isInteractionActive
        self.isFollowingCursor = isFollowingCursor

        guard configurationChanged else { return }

        if shouldScheduleHide {
            setHidden(false)
            scheduleHide()
        } else {
            cancelScheduledHide()
            setHidden(false)
        }
    }

    func recordActivity() {
        setHidden(false)
        guard shouldScheduleHide else {
            cancelScheduledHide()
            return
        }
        scheduleHide()
    }

    func stop() {
        cancelScheduledHide()
        setHidden(false)
    }

    private var shouldScheduleHide: Bool {
        isEnabled && !isInteractionActive && isFollowingCursor
    }

    private func scheduleHide() {
        cancelScheduledHide()
        let scheduledGeneration = UUID()
        scheduleGeneration = scheduledGeneration
        scheduledHideAction = scheduler(delaySeconds) { [weak self] in
            guard let self,
                  self.scheduleGeneration == scheduledGeneration,
                  self.shouldScheduleHide else { return }
            self.scheduledHideAction = nil
            self.setHidden(true)
        }
    }

    private func cancelScheduledHide() {
        scheduleGeneration = UUID()
        scheduledHideAction?.cancel()
        scheduledHideAction = nil
    }

    private func setHidden(_ shouldHide: Bool) {
        guard isHidden != shouldHide else { return }
        isHidden = shouldHide
        visibilityDidChange(shouldHide)
    }

    static func liveScheduler(
        delaySeconds: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> CompanionScheduledAction {
        let task = Task { @MainActor in
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
        return CompanionScheduledAction {
            task.cancel()
        }
    }
}

@MainActor
final class CompanionCursorTracker: ObservableObject {
    // Cursor interpolation is short-lived and stops 200 ms after movement.
    // The user prefers display-rate smoothness while moving; this does not
    // restore the former permanent 60 Hz update path.
    static let smoothingFramesPerSecond = 60.0
    static let movementSettlingDelaySeconds = 0.20

    static func shouldStopSmoothing(
        latestMouseMovementDate: Date,
        currentDate: Date
    ) -> Bool {
        currentDate.timeIntervalSince(latestMouseMovementDate) >= movementSettlingDelaySeconds
    }

    @Published private(set) var renderedMouseLocation: CGPoint
    @Published private(set) var activeScreenFrame: CGRect?
    @Published private(set) var isHiddenForInactivity = false

    private weak var companionManager: CompanionManager?
    private var availableScreenFrames: [CGRect]
    private var latestMouseLocation: CGPoint
    private var latestMouseMovementDate = Date()
    private var previousSmoothingFrameDate = Date()
    private var smoothingTimer: Timer?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var settingsCancellables: Set<AnyCancellable> = []
    private var autoHideController: CompanionAutoHideController!

    init(
        screenFrames: [CGRect],
        companionManager: CompanionManager,
        startsEventMonitoring: Bool = true,
        autoHideScheduler: @escaping CompanionAutoHideController.Scheduler = CompanionAutoHideController.liveScheduler
    ) {
        let initialMouseLocation = NSEvent.mouseLocation
        self.availableScreenFrames = screenFrames
        self.companionManager = companionManager
        self.latestMouseLocation = initialMouseLocation
        self.renderedMouseLocation = initialMouseLocation
        self.activeScreenFrame = CompanionOverlayGeometry.screenFrame(
            containing: initialMouseLocation,
            availableScreenFrames: screenFrames
        )
        self.autoHideController = CompanionAutoHideController(
            scheduler: autoHideScheduler,
            visibilityDidChange: { [weak self] isHidden in
                self?.isHiddenForInactivity = isHidden
            }
        )

        bindCompanionState()
        refreshAutoHideConfiguration()
        if startsEventMonitoring {
            startEventMonitoring()
        }
    }

    deinit {
        smoothingTimer?.invalidate()
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
    }

    func stop() {
        smoothingTimer?.invalidate()
        smoothingTimer = nil
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        settingsCancellables.removeAll()
        autoHideController.stop()
    }

    func recordMouseMovement(at mouseLocation: CGPoint, currentDate: Date = Date()) {
        let previousScreenFrame = activeScreenFrame
        latestMouseLocation = mouseLocation
        latestMouseMovementDate = currentDate
        activeScreenFrame = CompanionOverlayGeometry.screenFrame(
            containing: mouseLocation,
            availableScreenFrames: availableScreenFrames
        )
        autoHideController.recordActivity()

        guard let companionManager else { return }
        if companionManager.companionFollowResponse == .quick || previousScreenFrame != activeScreenFrame {
            stopSmoothing(at: mouseLocation)
            return
        }

        startSmoothingIfNeeded(currentDate: currentDate)
    }

    func applyAutoHideInteractionState(
        voiceState: CompanionVoiceState,
        hasActivePointingTarget: Bool
    ) {
        guard let companionManager else { return }
        autoHideController.configure(
            isEnabled: companionManager.isCompanionAutoHideEnabled,
            delaySeconds: companionManager.companionAutoHideDelaySeconds,
            isInteractionActive: voiceState != .idle || hasActivePointingTarget,
            isFollowingCursor: !hasActivePointingTarget
        )
    }

    private func startEventMonitoring() {
        let monitoredEvents: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: monitoredEvents) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordMouseMovement(at: NSEvent.mouseLocation)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: monitoredEvents) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.recordMouseMovement(at: NSEvent.mouseLocation)
            }
            return event
        }
    }

    private func bindCompanionState() {
        guard let companionManager else { return }

        companionManager.$voiceState
            .sink { [weak self] _ in self?.refreshAutoHideConfiguration() }
            .store(in: &settingsCancellables)
        companionManager.$detectedElementScreenLocation
            .sink { [weak self] _ in self?.refreshAutoHideConfiguration() }
            .store(in: &settingsCancellables)
        companionManager.$isCompanionAutoHideEnabled
            .sink { [weak self] _ in self?.refreshAutoHideConfiguration() }
            .store(in: &settingsCancellables)
        companionManager.$companionAutoHideDelaySeconds
            .sink { [weak self] _ in self?.refreshAutoHideConfiguration() }
            .store(in: &settingsCancellables)
        companionManager.$companionFollowResponse
            .sink { [weak self] followResponse in
                guard let self else { return }
                if followResponse == .quick {
                    self.stopSmoothing(at: self.latestMouseLocation)
                }
            }
            .store(in: &settingsCancellables)
    }

    private func refreshAutoHideConfiguration() {
        guard let companionManager else { return }
        applyAutoHideInteractionState(
            voiceState: companionManager.voiceState,
            hasActivePointingTarget: companionManager.detectedElementScreenLocation != nil
        )
    }

    private func startSmoothingIfNeeded(currentDate: Date) {
        guard smoothingTimer == nil else { return }
        previousSmoothingFrameDate = currentDate
        let frameInterval = 1.0 / Self.smoothingFramesPerSecond
        let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceSmoothing(currentDate: Date())
            }
        }
        smoothingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceSmoothing(currentDate: Date) {
        guard let companionManager else {
            stopSmoothing(at: latestMouseLocation)
            return
        }

        let frameDurationSeconds = max(
            currentDate.timeIntervalSince(previousSmoothingFrameDate),
            1.0 / Self.smoothingFramesPerSecond
        )
        previousSmoothingFrameDate = currentDate
        let smoothingFraction = companionManager.companionFollowResponse.smoothingFraction(
            frameDurationSeconds: frameDurationSeconds
        )
        let nextPosition = CGPoint(
            x: renderedMouseLocation.x + (latestMouseLocation.x - renderedMouseLocation.x) * smoothingFraction,
            y: renderedMouseLocation.y + (latestMouseLocation.y - renderedMouseLocation.y) * smoothingFraction
        )
        renderedMouseLocation = nextPosition

        if Self.shouldStopSmoothing(
            latestMouseMovementDate: latestMouseMovementDate,
            currentDate: currentDate
        ) {
            stopSmoothing(at: latestMouseLocation)
        }
    }

    private func stopSmoothing(at finalMouseLocation: CGPoint) {
        smoothingTimer?.invalidate()
        smoothingTimer = nil
        renderedMouseLocation = finalMouseLocation
    }
}
