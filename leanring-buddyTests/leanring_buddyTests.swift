//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import CoreGraphics
@testable import leanring_buddy

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

    @Test func pointParserAcceptsWellFormedCoordinateTag() async throws {
        let result = CompanionManager.parsePointingCoordinates(
            from: "点这里。[POINT:1263,94:三点菜单]"
        )

        #expect(result.spokenText == "点这里。")
        #expect(result.coordinate == CGPoint(x: 1263, y: 94))
        #expect(result.elementLabel == "三点菜单")
    }

    @Test func pointParserAcceptsMissingClosingBracketFromMiniMax() async throws {
        let result = CompanionManager.parsePointingCoordinates(
            from: "点这里。[POINT:1263,94:三点菜单"
        )

        #expect(result.spokenText == "点这里。")
        #expect(result.coordinate == CGPoint(x: 1263, y: 94))
        #expect(result.elementLabel == "三点菜单")
    }

}
