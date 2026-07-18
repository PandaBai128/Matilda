//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import CoreGraphics
@testable import Clicky

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

}
