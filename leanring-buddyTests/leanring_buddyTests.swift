//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import CoreGraphics
import Foundation
@testable import Matilda

@MainActor
struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func pointParserAcceptsWellFormedNormalizedCoordinateTag() async throws {
        let result = CompanionManager.parsePointingCoordinates(
            from: "点这里。[POINT_V2:305,259:关闭窗口]"
        )

        #expect(result.spokenText == "点这里。")
        #expect(result.coordinate == CGPoint(x: 305, y: 259))
        #expect(result.elementLabel == "关闭窗口")
    }

    @Test func pointParserAcceptsMissingClosingBracketFromMiniMax() async throws {
        let result = CompanionManager.parsePointingCoordinates(
            from: "点这里。[POINT_V2:305,259:关闭窗口"
        )

        #expect(result.spokenText == "点这里。")
        #expect(result.coordinate == CGPoint(x: 305, y: 259))
        #expect(result.elementLabel == "关闭窗口")
    }

    @Test func pointParserRejectsOutOfRangeNormalizedCoordinates() async throws {
        let result = CompanionManager.parsePointingCoordinates(
            from: "点这里。[POINT_V2:1263,94:关闭窗口]"
        )

        #expect(result.spokenText == "点这里。")
        #expect(result.coordinate == nil)
    }

    @Test func pointParserStripsMalformedV2TagWithoutMovingCursor() async throws {
        let result = CompanionManager.parsePointingCoordinates(
            from: "点这里。[POINT_V2:-20,10000:关闭窗口]"
        )

        #expect(result.spokenText == "点这里。")
        #expect(result.coordinate == nil)
    }

    @Test func pointParserAcceptsSecondaryScreenSuffix() async throws {
        let result = CompanionManager.parsePointingCoordinates(
            from: "点这里。[POINT_V2:305,259:关闭窗口:screen2]"
        )

        #expect(result.coordinate == CGPoint(x: 305, y: 259))
        #expect(result.elementLabel == "关闭窗口")
        #expect(result.screenNumber == 2)
    }

    @Test func pointParserStripsLegacyPixelTagWithoutMovingCursor() async throws {
        let result = CompanionManager.parsePointingCoordinates(
            from: "点这里。[POINT:1263,94:关闭窗口]"
        )

        #expect(result.spokenText == "点这里。")
        #expect(result.coordinate == nil)
    }

    @Test func normalizedCoordinateMapsToDisplayCenter() async throws {
        let displayFrame = CGRect(x: 100, y: -200, width: 1728, height: 1117)

        let screenLocation = CompanionManager.globalScreenLocation(
            fromNormalizedCoordinate: CGPoint(x: 500, y: 500),
            displayFrame: displayFrame
        )

        #expect(screenLocation == CGPoint(x: 964, y: 358.5))
    }

    @Test func normalizedCoordinateMapsTopLeftAndBottomRight() async throws {
        let displayFrame = CGRect(x: 100, y: -200, width: 1728, height: 1117)

        let topLeftScreenLocation = CompanionManager.globalScreenLocation(
            fromNormalizedCoordinate: CGPoint(x: 0, y: 0),
            displayFrame: displayFrame
        )
        let bottomRightScreenLocation = CompanionManager.globalScreenLocation(
            fromNormalizedCoordinate: CGPoint(x: 1000, y: 1000),
            displayFrame: displayFrame
        )

        #expect(topLeftScreenLocation == CGPoint(x: 100, y: 917))
        #expect(bottomRightScreenLocation == CGPoint(x: 1828, y: -200))
    }

    @Test func ordinaryKnowledgeQuestionDoesNotRequestPointing() async throws {
        #expect(!PointingRequestPolicy.shouldRequestPointing(
            for: "Codex 最近更新了哪些功能？"
        ))
    }

    @Test func copyableContentRequestDoesNotRequestPointing() async throws {
        #expect(!PointingRequestPolicy.shouldRequestPointing(
            for: "帮我写一段读取 JSON 的 Swift 代码"
        ))
    }

    @Test func questionAboutVisibleUIControlRequestsPointing() async throws {
        #expect(PointingRequestPolicy.shouldRequestPointing(
            for: "这个按钮为什么不能用？"
        ))
    }

    @Test func naturalLocationQuestionRequestsPointingWithoutKnownTargetType() async throws {
        #expect(PointingRequestPolicy.shouldRequestPointing(
            for: "小狗狗在哪里？"
        ))
    }

    @Test func currentPageIdentificationRequestsPointing() async throws {
        #expect(PointingRequestPolicy.shouldRequestPointing(
            for: "这个页面是什么？"
        ))
        #expect(PointingRequestPolicy.shouldRequestPointing(
            for: "这是什么页面？"
        ))
        #expect(PointingRequestPolicy.shouldRequestPointing(
            for: "那这是什么页面？"
        ))
    }

    @Test func visiblePageCloseGuidanceRequestsPointing() async throws {
        #expect(PointingRequestPolicy.shouldRequestPointing(
            for: "怎么关掉这个页面？"
        ))
        #expect(PointingRequestPolicy.shouldRequestPointing(
            for: "告诉我如何关掉",
            previousUserTranscript: "这是什么页面？"
        ))
        #expect(!PointingRequestPolicy.shouldRequestPointing(
            for: "如何关闭这个话题？"
        ))
    }

    @Test func nonVisualSearchDoesNotRequestPointing() async throws {
        #expect(!PointingRequestPolicy.shouldRequestPointing(
            for: "帮我找一下最近的 Codex 新闻"
        ))
    }

    @Test func abstractProblemLocationDoesNotRequestPointing() async throws {
        #expect(!PointingRequestPolicy.shouldRequestPointing(
            for: "帮我定位这个 bug 的原因"
        ))
    }

    @Test func explicitDesktopSearchRequestsPointing() async throws {
        #expect(PointingRequestPolicy.shouldRequestPointing(
            for: "帮我找一下桌面上的 Mavis 文件夹"
        ))
    }

    @Test func explicitLocationQuestionRequestsPointing() async throws {
        #expect(PointingRequestPolicy.shouldRequestPointing(
            for: "Chrome 浏览器在哪儿？"
        ))
    }

    @Test func streamingSpeechEmitsCompletedSentenceBeforeResponseFinishes() async throws {
        var segmenter = StreamingSpeechSegmenter()

        let firstSegments = segmenter.consume(accumulatedText: "这是 Codex。后面还")
        let finalSegments = segmenter.finish(finalAccumulatedText: "这是 Codex。后面还在生成。")

        #expect(firstSegments == ["这是 Codex。"])
        #expect(finalSegments == ["后面还在生成。"])
    }

    @Test func streamingSpeechNeverReadsCodeOrPointingTag() async throws {
        var segmenter = StreamingSpeechSegmenter()
        let response = "已经整理好了。```swift\nprint(\"hello\")\n```[POINT_V2:500,500:编辑器]"

        let firstSegments = segmenter.consume(accumulatedText: response)
        let finalSegments = segmenter.finish(finalAccumulatedText: response)

        #expect(firstSegments == ["已经整理好了。"])
        #expect(finalSegments.isEmpty)
    }

    @Test func streamingSpeechDoesNotInventChineseCopyNoticeForEnglishCode() async throws {
        var segmenter = StreamingSpeechSegmenter()
        let response = "Here is the result.```swift\nprint(\"hello\")\n```[POINT_V2:500,500:editor]"

        let firstSegments = segmenter.consume(accumulatedText: response)
        let finalSegments = segmenter.finish(finalAccumulatedText: response)
        let allSegments = firstSegments + finalSegments

        #expect(allSegments == ["Here is the result."])
        #expect(!allSegments.joined().contains("内容已经写好"))
        #expect(!allSegments.joined().contains("print"))
        #expect(!allSegments.joined().contains("POINT_V2"))
    }

    @Test func abstractLocationQuestionsDoNotRequestPointing() async throws {
        #expect(!PointingRequestPolicy.shouldRequestPointing(for: "幸福在哪里？"))
        #expect(!PointingRequestPolicy.shouldRequestPointing(for: "问题出在哪里？"))
        #expect(!PointingRequestPolicy.shouldRequestPointing(for: "Where is happiness?"))
    }

    @Test func geographicLocationQuestionsDoNotRequestPointing() async throws {
        #expect(!PointingRequestPolicy.shouldRequestPointing(for: "中国在哪里？"))
        #expect(!PointingRequestPolicy.shouldRequestPointing(for: "Where is China?"))
    }

    @Test func responseLengthModesProvideDistinctPromptInstructions() async throws {
        #expect(CompanionResponseLength.brief.systemPromptInstruction.contains("one or two"))
        #expect(CompanionResponseLength.normal.systemPromptInstruction.contains("two to four"))
        #expect(CompanionResponseLength.detailed.systemPromptInstruction.contains("thorough"))
    }

    @Test func currentVideoFrameTextExtractionRequestsDetailedScreenshot() async throws {
        #expect(ScreenTextExtractionPolicy.isTextExtractionRequest(
            "把当前视频画面里的文字提取出来"
        ))
        #expect(!ScreenTextExtractionPolicy.isTextExtractionRequest(
            "这个页面是什么？"
        ))
    }

    @Test func mediumCursorDistanceMatchesOriginalPointerSpacing() async throws {
        let cursorOffset = CompanionCursorDistance.medium.cursorOffset(for: .medium)

        #expect(cursorOffset == CGPoint(x: 35, y: 25))
    }

    @Test func followResponseModesMatchTheRequestedSpeedRemapping() async throws {
        let frameDurationSeconds = 1.0 / 60.0
        let fastFraction = CompanionFollowResponse.quick.smoothingFraction(
            frameDurationSeconds: frameDurationSeconds
        )
        let mediumFraction = CompanionFollowResponse.natural.smoothingFraction(
            frameDurationSeconds: frameDurationSeconds
        )
        let slowFraction = CompanionFollowResponse.relaxed.smoothingFraction(
            frameDurationSeconds: frameDurationSeconds
        )

        let previousFastFraction = CGFloat(1 - exp(-frameDurationSeconds / 0.12))
        let previousMediumFraction = CGFloat(1 - exp(-frameDurationSeconds / 0.22))

        #expect(CompanionFollowResponse.quick.displayName == "Fast")
        #expect(CompanionFollowResponse.natural.displayName == "Medium")
        #expect(CompanionFollowResponse.relaxed.displayName == "Slow")
        #expect(fastFraction == 1)
        #expect(abs(mediumFraction - previousFastFraction) < 0.000_001)
        #expect(abs(slowFraction - previousMediumFraction) < 0.000_001)
        #expect(CompanionCursorTracker.smoothingFramesPerSecond == 60)
        #expect(CompanionCursorTracker.movementSettlingDelaySeconds == 0.20)
        let latestMovementDate = Date(timeIntervalSinceReferenceDate: 100)
        #expect(!CompanionCursorTracker.shouldStopSmoothing(
            latestMouseMovementDate: latestMovementDate,
            currentDate: latestMovementDate.addingTimeInterval(0.199)
        ))
        #expect(CompanionCursorTracker.shouldStopSmoothing(
            latestMouseMovementDate: latestMovementDate,
            currentDate: latestMovementDate.addingTimeInterval(0.20)
        ))
    }

    @Test func companionAutoHideReschedulesWithoutAllowingStaleDeadlinesToHide() async throws {
        let testScheduler = TestCompanionAutoHideScheduler()
        var visibilityChanges: [Bool] = []
        let controller = CompanionAutoHideController(
            scheduler: testScheduler.schedule,
            visibilityDidChange: { visibilityChanges.append($0) }
        )

        #expect(CompanionManager.defaultCompanionAutoHideDelaySeconds == 10)
        controller.configure(
            isEnabled: true,
            delaySeconds: 10,
            isInteractionActive: false,
            isFollowingCursor: true
        )
        controller.recordActivity()

        #expect(testScheduler.entries.count == 2)
        #expect(testScheduler.entries[0].isCancelled)
        testScheduler.fireEntry(at: 0)
        #expect(!controller.isHidden)

        testScheduler.fireEntry(at: 1)
        #expect(controller.isHidden)
        #expect(visibilityChanges == [true])

        controller.recordActivity()
        #expect(!controller.isHidden)
        controller.configure(
            isEnabled: true,
            delaySeconds: 10,
            isInteractionActive: true,
            isFollowingCursor: true
        )
        testScheduler.fireEntry(at: 2)
        #expect(!controller.isHidden)
        #expect(visibilityChanges == [true, false])
    }

    @Test func animationCadenceMatchesInteractionCost() async throws {
        #expect(CompanionAnimationCadencePolicy.framesPerSecond(
            voiceState: .idle,
            navigationMode: .followingCursor
        ) == nil)
        #expect(CompanionAnimationCadencePolicy.framesPerSecond(
            voiceState: .responding,
            navigationMode: .followingCursor
        ) == nil)
        #expect(CompanionAnimationCadencePolicy.framesPerSecond(
            voiceState: .processing,
            navigationMode: .followingCursor
        ) == 12)
        #expect(CompanionAnimationCadencePolicy.framesPerSecond(
            voiceState: .listening,
            navigationMode: .followingCursor
        ) == 24)
        #expect(CompanionAnimationCadencePolicy.framesPerSecond(
            voiceState: .idle,
            navigationMode: .pointingAtTarget
        ) == 24)
        #expect(CompanionAnimationCadencePolicy.framesPerSecond(
            voiceState: .idle,
            navigationMode: .navigatingToTarget
        ) == 30)
    }

    @Test func activeScreenSelectionReturnsOnlyTheScreenContainingTheMouse() async throws {
        let leftScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let mainScreen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

        #expect(CompanionOverlayGeometry.screenFrame(
            containing: CGPoint(x: -400, y: 600),
            availableScreenFrames: [leftScreen, mainScreen]
        ) == leftScreen)
        #expect(CompanionOverlayGeometry.screenFrame(
            containing: CGPoint(x: 900, y: 500),
            availableScreenFrames: [leftScreen, mainScreen]
        ) == mainScreen)
        #expect(CompanionOverlayGeometry.screenFrame(
            containing: CGPoint(x: 3000, y: 500),
            availableScreenFrames: [leftScreen, mainScreen]
        ) == nil)
    }

    @Test func targetMarkerCenterPreservesAllScreenEdgesAndCorners() async throws {
        let displayFrame = CGRect(x: 100, y: -200, width: 1728, height: 1117)
        let normalizedCoordinates = [
            CGPoint(x: 0, y: 0), CGPoint(x: 500, y: 0), CGPoint(x: 1000, y: 0),
            CGPoint(x: 0, y: 500), CGPoint(x: 1000, y: 500),
            CGPoint(x: 0, y: 1000), CGPoint(x: 500, y: 1000), CGPoint(x: 1000, y: 1000)
        ]
        let expectedLocalCoordinates = [
            CGPoint(x: 0, y: 0), CGPoint(x: 864, y: 0), CGPoint(x: 1728, y: 0),
            CGPoint(x: 0, y: 558.5), CGPoint(x: 1728, y: 558.5),
            CGPoint(x: 0, y: 1117), CGPoint(x: 864, y: 1117), CGPoint(x: 1728, y: 1117)
        ]

        for (normalizedCoordinate, expectedLocalCoordinate) in zip(
            normalizedCoordinates,
            expectedLocalCoordinates
        ) {
            let globalCoordinate = CompanionManager.globalScreenLocation(
                fromNormalizedCoordinate: normalizedCoordinate,
                displayFrame: displayFrame
            )
            let markerCenter = CompanionOverlayGeometry.localPoint(
                forGlobalScreenPoint: globalCoordinate,
                screenFrame: displayFrame
            )
            #expect(markerCenter == expectedLocalCoordinate)
        }
    }

    @Test func responseFailureMessagesAreAccurateAndNeutral() async throws {
        let networkMessage = CompanionResponseFailureMessage.spokenMessage(for: URLError(.timedOut))
        let genericMessage = CompanionResponseFailureMessage.spokenMessage(
            for: NSError(domain: "MatildaTest", code: 1)
        )

        #expect(networkMessage.contains("网络"))
        #expect(genericMessage.contains("没有成功"))
        #expect(!networkMessage.localizedCaseInsensitiveContains("credit"))
        #expect(!genericMessage.localizedCaseInsensitiveContains("Farza"))
    }

    @Test func sourceDoesNotPersistOrPrintSensitiveConversationContent() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sensitiveSourceFiles = [
            "leanring-buddy/CompanionManager.swift",
            "leanring-buddy/BuddyDictationManager.swift",
            "leanring-buddy/ElevenLabsTTSClient.swift"
        ]
        let combinedSource = try sensitiveSourceFiles.map { relativePath in
            try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
        }.joined(separator: "\n")

        #expect(!combinedSource.contains("/tmp/clicky-debug.log"))
        #expect(!combinedSource.contains("clickyDebugSnippet"))
        #expect(!combinedSource.contains("received transcript:"))
        #expect(!combinedSource.contains("llm full-response"))
    }

    @Test func blinkTimingClosesThenReopensTheImageFrame() async throws {
        let fullyClosedProgress = ZhuangzhuangExpressionTiming.blinkProgress(
            elapsedTime: 0.17,
            cycleDurationSeconds: 5.8
        )
        let reopenedProgress = ZhuangzhuangExpressionTiming.blinkProgress(
            elapsedTime: 0.40,
            cycleDurationSeconds: 5.8
        )

        #expect(fullyClosedProgress > 0.99)
        #expect(reopenedProgress == 0)
    }

    @Test func barkTimingShowsTwoMouthOpeningsAndARestingBeat() async throws {
        let firstBarkProgress = ZhuangzhuangExpressionTiming.barkProgress(elapsedTime: 0.21)
        let secondBarkProgress = ZhuangzhuangExpressionTiming.barkProgress(elapsedTime: 0.59)
        let restingProgress = ZhuangzhuangExpressionTiming.barkProgress(elapsedTime: 1.10)

        #expect(firstBarkProgress > 0.99)
        #expect(secondBarkProgress > 0.99)
        #expect(restingProgress == 0)
    }

}

@MainActor
private final class TestCompanionAutoHideScheduler {
    final class Entry {
        let action: @MainActor () -> Void
        var isCancelled = false

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }
    }

    private(set) var entries: [Entry] = []

    func schedule(
        delaySeconds: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> CompanionScheduledAction {
        let entry = Entry(action: action)
        entries.append(entry)
        return CompanionScheduledAction {
            entry.isCancelled = true
        }
    }

    func fireEntry(at index: Int) {
        entries[index].action()
    }
}
