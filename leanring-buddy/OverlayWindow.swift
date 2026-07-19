//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for the companion avatar.
//  One OverlayWindow is created per screen. All windows share one
//  event-driven cursor tracker so inactive displays do no recurring work.
//

import AppKit
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode: Equatable {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

enum ZhuangzhuangExpressionTiming {
    static let barkCycleDurationSeconds: TimeInterval = 1.45

    static func blinkProgress(
        elapsedTime: TimeInterval,
        cycleDurationSeconds: TimeInterval
    ) -> CGFloat {
        let blinkDurationSeconds = 0.34
        let timeWithinBlinkCycle = elapsedTime.truncatingRemainder(
            dividingBy: cycleDurationSeconds
        )
        guard timeWithinBlinkCycle < blinkDurationSeconds else { return 0 }

        let normalizedBlinkProgress = timeWithinBlinkCycle / blinkDurationSeconds
        return CGFloat(sin(normalizedBlinkProgress * .pi))
    }

    static func barkProgress(elapsedTime: TimeInterval) -> CGFloat {
        let timeWithinBarkCycle = elapsedTime.truncatingRemainder(
            dividingBy: barkCycleDurationSeconds
        )
        let firstBarkProgress = singleBarkProgress(
            timeWithinBarkCycle: timeWithinBarkCycle,
            startTime: 0.08
        )
        let secondBarkProgress = singleBarkProgress(
            timeWithinBarkCycle: timeWithinBarkCycle,
            startTime: 0.46
        )
        return max(firstBarkProgress, secondBarkProgress)
    }

    private static func singleBarkProgress(
        timeWithinBarkCycle: TimeInterval,
        startTime: TimeInterval
    ) -> CGFloat {
        let barkDurationSeconds = 0.26
        let elapsedBarkTime = timeWithinBarkCycle - startTime
        guard elapsedBarkTime >= 0, elapsedBarkTime < barkDurationSeconds else { return 0 }

        let normalizedBarkProgress = elapsedBarkTime / barkDurationSeconds
        return CGFloat(sin(normalizedBarkProgress * .pi))
    }
}

// SwiftUI view for the Zhuangzhuang cursor companion.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// avatar when it is. Voice and navigation states animate the same approved
// identity frames so facial proportions remain stable during expression changes.
struct BlueCursorView: View {
    let screenFrame: CGRect
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var cursorTracker: CompanionCursorTracker

    @State private var cursorPosition: CGPoint

    init(
        screenFrame: CGRect,
        companionManager: CompanionManager,
        cursorTracker: CompanionCursorTracker
    ) {
        self.screenFrame = screenFrame
        self.companionManager = companionManager
        self.cursorTracker = cursorTracker

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = cursorTracker.renderedMouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        let cursorOffset = companionManager.companionCursorDistance.cursorOffset(
            for: companionManager.companionAvatarSize
        )
        _cursorPosition = State(initialValue: CGPoint(x: localX + cursorOffset.x, y: localY + cursorOffset.y))
    }
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// A restrained head tilt that follows the direction of travel.
    @State private var buddyTravelTiltDegrees: Double = 0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy portrait during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0
    @State private var pointingTargetPosition: CGPoint?

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    private let navigationPointerPhrase = "汪，汪汪"

    var body: some View {
        ZStack {
            Color.clear

            if buddyNavigationMode == .pointingAtTarget,
               let pointingTargetPosition {
                ZhuangzhuangTargetMarkerView(
                    diameter: CGFloat(companionManager.companionPointingMarkerDiameter),
                    markerColor: companionManager.companionPointingMarkerColor,
                    showsCenterDot: companionManager.isCompanionPointingCenterDotEnabled
                )
                .position(pointingTargetPosition)
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(companionManager.companionPointingLabelForegroundColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(companionManager.companionPointingLabelBackgroundColor)
                            .shadow(
                                color: companionManager.companionPointingLabelBackgroundColor.opacity(
                                    0.5 + (1.0 - navigationBubbleScale) * 1.0
                                ),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(
                        x: cursorPosition.x + 8 + (navigationBubbleSize.width / 2),
                        y: cursorPosition.y + (companionManager.companionAvatarSize.diameter / 2) + 12
                    )
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            if buddyIsVisibleOnThisScreen {
                // Removing this subtree stops its TimelineView completely after
                // auto-hide or when another display becomes active.
                ZhuangzhuangAvatarView(
                    diameter: companionManager.companionAvatarSize.diameter,
                    voiceState: companionManager.voiceState,
                    navigationMode: buddyNavigationMode,
                    audioPowerLevel: companionManager.currentAudioPowerLevel,
                    travelTiltDegrees: buddyTravelTiltDegrees,
                    glowColor: companionManager.companionGlowColor,
                    glowIntensity: companionManager.companionGlowIntensity,
                    isGlowEnabled: companionManager.isCompanionGlowEnabled
                )
                .scaleEffect(buddyFlightScale)
                .opacity(cursorOpacity)
                .position(cursorPosition)
                .transition(.opacity)
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)
            }

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            let mouseLocation = cursorTracker.renderedMouseLocation
            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            let cursorOffset = currentCursorOffset
            self.cursorPosition = CGPoint(
                x: swiftUIPosition.x + cursorOffset.x,
                y: swiftUIPosition.y + cursorOffset.y
            )

            self.cursorOpacity = 1.0
        }
        .onDisappear {
            navigationAnimationTimer?.invalidate()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            // When a UI element location is detected, navigate the buddy to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                return
            }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
        .onChange(of: cursorTracker.renderedMouseLocation) { _, newMouseLocation in
            handleTrackedMouseLocation(newMouseLocation)
        }
        .onChange(of: cursorTracker.activeScreenFrame) { _, newActiveScreenFrame in
            guard newActiveScreenFrame == screenFrame else { return }
            handleTrackedMouseLocation(cursorTracker.renderedMouseLocation)
        }
        .animation(.easeInOut(duration: 0.24), value: buddyIsVisibleOnThisScreen)
    }

    /// Whether the buddy avatar should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return cursorTracker.activeScreenFrame == screenFrame
                && !cursorTracker.isHiddenForInactivity
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func handleTrackedMouseLocation(_ mouseLocation: CGPoint) {
        if buddyNavigationMode == .navigatingToTarget && isReturningToCursor {
            let currentMouseInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
            let distanceFromNavigationStart = hypot(
                currentMouseInSwiftUI.x - cursorPositionWhenNavigationStarted.x,
                currentMouseInSwiftUI.y - cursorPositionWhenNavigationStarted.y
            )
            if distanceFromNavigationStart > 100 {
                cancelNavigationAndResumeFollowing()
            }
            return
        }

        guard buddyNavigationMode == .followingCursor,
              cursorTracker.activeScreenFrame == screenFrame else { return }

        let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorOffset = currentCursorOffset
        cursorPosition = CGPoint(
            x: swiftUIPosition.x + cursorOffset.x,
            y: swiftUIPosition.y + cursorOffset.y
        )
    }

    private var currentCursorOffset: CGPoint {
        companionManager.companionCursorDistance.cursorOffset(
            for: companionManager.companionAvatarSize
        )
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        CompanionOverlayGeometry.localPoint(
            forGlobalScreenPoint: screenPoint,
            screenFrame: screenFrame
        )
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // The marker center is the model coordinate exactly. The ring may crop at
        // an edge, but the center dot must never report a shifted location.
        let markerPosition = targetInSwiftUI
        pointingTargetPosition = markerPosition

        let avatarDiameter = companionManager.companionAvatarSize.diameter
        let clampedTarget = CompanionOverlayGeometry.clampedAvatarDestination(
            beside: markerPosition,
            avatarDiameter: avatarDiameter,
            screenSize: screenFrame.size
        )

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The portrait tilts toward its direction
    /// of travel each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 30.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Tilt toward the direction of travel without rotating the face
            // upside down along steep arcs.
            // to the bezier curve. B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            let travelAngle = atan2(tangentY, tangentX) * (180.0 / .pi)
            self.buddyTravelTiltDegrees = min(max(travelAngle * 0.12, -10), 10)

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        buddyTravelTiltDegrees = -5

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        streamNavigationBubbleCharacter(phrase: navigationPointerPhrase, characterIndex: 0) {
            // All characters streamed — hold for 3 seconds, then fly back
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorOffset = currentCursorOffset
        let cursorWithTrackingOffset = CGPoint(
            x: cursorInSwiftUI.x + cursorOffset.x,
            y: cursorInSwiftUI.y + cursorOffset.y
        )

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        pointingTargetPosition = nil
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        buddyTravelTiltDegrees = 0
        buddyFlightScale = 1.0
        pointingTargetPosition = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        companionManager.clearDetectedElementLocation()
    }

}

// MARK: - Zhuangzhuang Avatar

struct ZhuangzhuangAvatarView: View {
    let diameter: CGFloat
    let voiceState: CompanionVoiceState
    let navigationMode: BuddyNavigationMode
    let audioPowerLevel: CGFloat
    let travelTiltDegrees: Double
    let glowColor: Color
    let glowIntensity: Double
    let isGlowEnabled: Bool
    var blinkCycleDurationSeconds: Double = 5.8
    @State private var expressionStateStartTime = Date().timeIntervalSinceReferenceDate
    @State private var isLowPowerBlinkVisible = false
    @State private var lowPowerBlinkTask: Task<Void, Never>?

    var body: some View {
        let framesPerSecond = CompanionAnimationCadencePolicy.framesPerSecond(
            voiceState: voiceState,
            navigationMode: navigationMode
        )
        Group {
            if let framesPerSecond {
                TimelineView(.periodic(from: .now, by: 1.0 / framesPerSecond)) { timelineContext in
                    animatedAvatarFrame(
                        animationTime: timelineContext.date.timeIntervalSinceReferenceDate
                    )
                }
            } else {
                lowPowerAvatarFrame
            }
        }
        .onAppear { refreshLowPowerBlinkTask() }
        .onDisappear {
            lowPowerBlinkTask?.cancel()
            lowPowerBlinkTask = nil
        }
        .onChange(of: navigationMode) { _, _ in
            expressionStateStartTime = Date().timeIntervalSinceReferenceDate
            refreshLowPowerBlinkTask()
        }
        .onChange(of: voiceState) { _, _ in
            expressionStateStartTime = Date().timeIntervalSinceReferenceDate
            refreshLowPowerBlinkTask()
        }
        .onChange(of: blinkCycleDurationSeconds) { _, _ in
            expressionStateStartTime = Date().timeIntervalSinceReferenceDate
            refreshLowPowerBlinkTask()
        }
    }

    @ViewBuilder
    private func animatedAvatarFrame(animationTime: TimeInterval) -> some View {
        avatarImageStack(
            animationTime: animationTime,
            blinkProgress: blinkProgress(at: animationTime),
            barkProgress: barkProgress(at: animationTime)
        )
        .rotationEffect(.degrees(rotationDegrees(at: animationTime)))
        .scaleEffect(scale(at: animationTime))
        .offset(offset(at: animationTime))
    }

    private var lowPowerAvatarFrame: some View {
        avatarImageStack(
            animationTime: expressionStateStartTime,
            blinkProgress: isLowPowerBlinkVisible ? 1 : 0,
            barkProgress: 0
        )
    }

    @ViewBuilder
    private func avatarImageStack(
        animationTime: TimeInterval,
        blinkProgress: CGFloat,
        barkProgress: CGFloat
    ) -> some View {
        ZStack {
            Image("ZhuangzhuangHead")
                .resizable()
                .scaledToFit()
                .frame(width: diameter, height: diameter)

            if blinkProgress > 0 {
                Image("ZhuangzhuangHeadClosedEyes")
                    .resizable()
                    .scaledToFit()
                    .frame(width: diameter, height: diameter)
                    .opacity(blinkProgress)
            }

            if barkProgress > 0 {
                Image("ZhuangzhuangHeadBark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: diameter, height: diameter)
                    .opacity(barkProgress)
            }

            if voiceState == .listening {
                BlueCursorWaveformView(
                    audioPowerLevel: audioPowerLevel,
                    accentColor: glowColor,
                    animationTime: animationTime
                )
                .offset(x: diameter * 0.72, y: diameter * 0.08)
            }

            if voiceState == .processing {
                ZhuangzhuangThinkingDotsView(
                    diameter: diameter,
                    animationTime: animationTime,
                    accentColor: glowColor
                )
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(
            color: glowColor.opacity(glowOpacity),
            radius: navigationMode == .navigatingToTarget ? diameter * 0.36 : diameter * 0.22,
            x: 0,
            y: 0
        )
    }

    private func refreshLowPowerBlinkTask() {
        lowPowerBlinkTask?.cancel()
        lowPowerBlinkTask = nil
        isLowPowerBlinkVisible = false

        guard CompanionAnimationCadencePolicy.framesPerSecond(
            voiceState: voiceState,
            navigationMode: navigationMode
        ) == nil else { return }

        lowPowerBlinkTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(blinkCycleDurationSeconds * 1_000_000_000)
                )
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.10)) {
                    isLowPowerBlinkVisible = true
                }
                try? await Task.sleep(nanoseconds: 170_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    isLowPowerBlinkVisible = false
                }
            }
        }
    }

    private func rotationDegrees(at animationTime: TimeInterval) -> Double {
        switch navigationMode {
        case .navigatingToTarget:
            return travelTiltDegrees
        case .pointingAtTarget:
            return -5 + sin(animationTime * 3.2) * 2.2
        case .followingCursor:
            break
        }

        switch voiceState {
        case .idle:
            return sin(animationTime * 1.05) * 2.4
        case .listening:
            return -12 + sin(animationTime * 2.1) * 2.6
        case .processing:
            return 15 + sin(animationTime * 1.7) * 3.0
        case .responding:
            return sin(animationTime * 1.6) * 1.8
        }
    }

    private func scale(at animationTime: TimeInterval) -> CGFloat {
        if navigationMode == .pointingAtTarget {
            return 1 + barkProgress(at: animationTime) * 0.035
        }
        if voiceState == .listening {
            let normalizedAudioPower = min(max(audioPowerLevel * 1.7, 0), 1)
            return 1 + normalizedAudioPower * 0.055
        }
        return 1 + CGFloat(sin(animationTime * 1.45)) * 0.022
    }

    private func offset(at animationTime: TimeInterval) -> CGSize {
        let horizontalMovement = CGFloat(sin(animationTime * 0.9)) * diameter * 0.035
        let verticalMovement = CGFloat(sin(animationTime * 1.25 + 0.8)) * diameter * 0.055
        return CGSize(width: horizontalMovement, height: verticalMovement)
    }

    private var glowOpacity: Double {
        guard isGlowEnabled else { return 0 }
        let navigationMultiplier = navigationMode == .navigatingToTarget ? 1.0 : 0.72
        return min(glowIntensity * navigationMultiplier, 1)
    }

    private func blinkProgress(at animationTime: TimeInterval) -> CGFloat {
        guard navigationMode == .followingCursor,
              voiceState == .idle || voiceState == .responding else {
            return 0
        }

        return ZhuangzhuangExpressionTiming.blinkProgress(
            elapsedTime: max(0, animationTime - expressionStateStartTime),
            cycleDurationSeconds: blinkCycleDurationSeconds
        )
    }

    private func barkProgress(at animationTime: TimeInterval) -> CGFloat {
        guard navigationMode == .pointingAtTarget else { return 0 }

        return ZhuangzhuangExpressionTiming.barkProgress(
            elapsedTime: max(0, animationTime - expressionStateStartTime)
        )
    }
}

private struct ZhuangzhuangThinkingDotsView: View {
    let diameter: CGFloat
    let animationTime: TimeInterval
    let accentColor: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: max(1, diameter * 0.045)) {
            ForEach(0..<3, id: \.self) { dotIndex in
                let wave = CGFloat((sin(animationTime * 4.2 + Double(dotIndex) * 0.9) + 1) / 2)
                Circle()
                    .fill(accentColor)
                    .frame(
                        width: diameter * (0.10 + wave * 0.025),
                        height: diameter * (0.10 + wave * 0.025)
                    )
                    .offset(y: -CGFloat(wave) * diameter * 0.10)
            }
        }
        .offset(x: diameter * 0.48, y: -diameter * 0.53)
        .shadow(color: accentColor.opacity(0.65), radius: diameter * 0.12)
    }
}

struct ZhuangzhuangTargetMarkerView: View {
    let diameter: CGFloat
    let markerColor: Color
    let showsCenterDot: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { timelineContext in
            let phase = CGFloat((sin(timelineContext.date.timeIntervalSinceReferenceDate * 4.0) + 1) / 2)
            ZStack {
                Circle()
                    .stroke(
                        markerColor.opacity(Double(0.82 - phase * 0.34)),
                        lineWidth: max(1.5, diameter * 0.055)
                    )
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(0.82 + phase * 0.28)

                if showsCenterDot {
                    Circle()
                        .fill(markerColor)
                        .frame(
                            width: max(4, diameter * 0.16),
                            height: max(4, diameter * 0.16)
                        )
                }
            }
            .frame(width: diameter * 1.12, height: diameter * 1.12)
            .shadow(color: markerColor.opacity(0.68), radius: diameter * 0.22)
        }
    }
}

// MARK: - Listening Waveform

/// A small waveform that reacts beside Zhuangzhuang while the user speaks.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat
    let accentColor: Color
    let animationTime: TimeInterval

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { barIndex in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(accentColor)
                    .frame(
                        width: 2,
                        height: barHeight(for: barIndex)
                    )
            }
        }
        .shadow(color: accentColor.opacity(0.6), radius: 6, x: 0, y: 0)
    }

    private func barHeight(for barIndex: Int) -> CGFloat {
        let animationPhase = CGFloat(animationTime * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    private var cursorTracker: CompanionCursorTracker?

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        let cursorTracker = CompanionCursorTracker(
            screenFrames: screens.map(\.frame),
            companionManager: companionManager
        )
        self.cursorTracker = cursorTracker

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                companionManager: companionManager,
                cursorTracker: cursorTracker
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        cursorTracker?.stop()
        cursorTracker = nil
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        cursorTracker?.stop()
        cursorTracker = nil
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}
