import Foundation
import CoreGraphics
import Testing
@testable import Matilda

struct CompanionAppearanceMotionTests {
    @Test func customBubbleStaysInsideScreenWithoutMovingTheTarget() {
        let bubble = CGSize(width: 370, height: 26)
        let screen = CGSize(width: 600, height: 400)
        for point in [CGPoint.zero, CGPoint(x: 600, y: 400)] {
            let center = CompanionAppearanceMotion.bubbleCenter(proposed: point, size: bubble, container: screen)
            #expect(center.x - bubble.width / 2 >= 8)
            #expect(center.x + bubble.width / 2 <= screen.width - 8)
            #expect(center.y - bubble.height / 2 >= 8)
            #expect(center.y + bubble.height / 2 <= screen.height - 8)
        }
    }

    @Test func firstBlinkPrecedesFiveSecondAutoHideWithoutRapidRepeating() {
        var schedule = CompanionBlinkSchedule(now: 100)
        #expect(schedule.nextBlinkTime < 105)
        // Repeated presentation updates do not postpone a pending blink.
        for tick in 0..<24 {
            let blinkDue = schedule.consumeIfDue(now: 100 + Double(tick) * 0.1)
            #expect(!blinkDue)
        }
        let firstBlinkDue = schedule.consumeIfDue(now: 102.4)
        let immediateSecondBlinkDue = schedule.consumeIfDue(now: 102.5)
        #expect(firstBlinkDue)
        #expect(!immediateSecondBlinkDue)
        #expect(abs(schedule.nextBlinkTime - 110.9) < 0.0001)
        let laterBlinkDue = schedule.consumeIfDue(now: 110.9)
        #expect(laterBlinkDue)
    }

    @Test func pointingBubbleSupportsUserChoiceWithoutInventingTarget() throws {
        #expect(CompanionPointingLabelMode.bark.text(target: "保存", custom: "") == "汪，汪汪")
        #expect(CompanionPointingLabelMode.targetName.text(target: "保存", custom: "") == "保存")
        #expect(CompanionPointingLabelMode.targetName.text(target: nil, custom: "") == "")
        #expect(CompanionPointingLabelMode.hidden.text(target: "保存", custom: "文字") == "")
        #expect(CompanionPointingLabelMode.custom.text(target: "保存", custom: "  在这里\n呀  ") == "在这里 呀")
        #expect(CompanionPointingLabelMode.custom.text(target: nil, custom: String(repeating: "字", count: 80)).count == 32)
        let name = "PointingBubbleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(CompanionPointingLabelMode.load(from: defaults) == .bark)
        defaults.set("hidden", forKey: CompanionPointingLabelMode.preferenceKey)
        #expect(CompanionPointingLabelMode.load(from: defaults) == .hidden)
    }

    @Test func gazeIsDirectionalBoundedAndFinite() {
        #expect(CompanionAppearanceMotion.gaze(from: .zero, toward: .zero) == .zero)
        let gaze = CompanionAppearanceMotion.gaze(from: .zero, toward: CGPoint(x: -900, y: 400))
        #expect(gaze.x < 0 && gaze.y > 0)
        #expect(abs(hypot(gaze.x, gaze.y) - 1) < 0.0001)
        #expect(CompanionAppearanceMotion.headFrame(gaze: gaze, listening: false, blinking: false, nodding: false) == 1)
    }

    @Test func listeningAndFeedbackOverridePassiveGaze() {
        let gaze = CGPoint(x: 1, y: 0)
        #expect(CompanionAppearanceMotion.headFrame(gaze: gaze, listening: true, blinking: false, nodding: false) == 3)
        #expect(CompanionAppearanceMotion.headFrame(gaze: gaze, listening: false, blinking: true, nodding: false) == 4)
        #expect(CompanionAppearanceMotion.headFrame(gaze: gaze, listening: false, blinking: false, nodding: true) == 5)
        #expect(CompanionAppearanceMotion.shouldHoldPosition(voiceState: .listening))
        #expect(CompanionAppearanceMotion.shouldHoldPosition(voiceState: .processing))
        #expect(!CompanionAppearanceMotion.shouldHoldPosition(voiceState: .responding))
    }

    @Test func bodyWalkFramesStopWhenCursorStops() {
        #expect(CompanionAppearanceMotion.bodyFrame(moving: true, resting: false, time: 0) == 1)
        #expect(CompanionAppearanceMotion.bodyFrame(moving: true, resting: false, time: 0.3) == 2)
        #expect(CompanionAppearanceMotion.bodyFrame(moving: false, resting: true, time: 999) == 3)
        #expect(CompanionAppearanceMotion.bodyFrame(moving: false, resting: false, time: 999) == 0)
    }

    @Test func portraitIsDefaultAndAppearanceChoicePersists() throws {
        let name = "CompanionAppearanceMotionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(CompanionVisualStyle.load(from: defaults) == .portrait)
        defaults.set("petiteBody", forKey: CompanionVisualStyle.preferenceKey)
        #expect(CompanionVisualStyle.load(from: defaults) == .petiteBody)
        defaults.set("unknown", forKey: CompanionVisualStyle.preferenceKey)
        #expect(CompanionVisualStyle.load(from: defaults) == .portrait)
    }

    @Test func walkingArtworkKeepsOnePawBaseline() {
        let firstBaseline = 625.0 / 627 + CompanionAppearanceMotion.bodyRegistration(for: 1).y
        let secondBaseline = 588.0 / 627 + CompanionAppearanceMotion.bodyRegistration(for: 2).y
        #expect(abs(firstBaseline - secondBaseline) < 0.002)
    }
}
