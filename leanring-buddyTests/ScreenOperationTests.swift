import Testing
import AppKit
@testable import Matilda

@MainActor
@Suite(.serialized)
struct ScreenOperationTests {
    @Test(.enabled(if: UserDefaults.standard.bool(forKey: "matildaRunNativeOperationAcceptance")))
    func nativeEventsAndDirectWindowClosingReachDisposableReceiver() async throws {
        let previousSetting = UserDefaults.standard.object(forKey: ScreenOperationPolicy.preferenceKey)
        let receiver = NativeOperationEventReceiver(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let window = NSWindow(contentRect: receiver.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Matilda Developer Acceptance"
        window.isReleasedWhenClosed = false
        window.contentView = receiver
        window.center()
        defer {
            window.close()
            if let previousSetting { UserDefaults.standard.set(previousSetting, forKey: ScreenOperationPolicy.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: ScreenOperationPolicy.preferenceKey) }
        }
        UserDefaults.standard.set(true, forKey: ScreenOperationPolicy.preferenceKey)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        let controller = ScreenOperationController()
        let screenPoint = window.convertPoint(toScreen: NSPoint(x: receiver.bounds.midX, y: receiver.bounds.midY))
        for instruction in ["点击测试区域", "双击测试区域", "右键测试区域", "向下滚动一点"] {
            let request = try #require(ScreenOperationPolicy.request(for: instruction))
            let reference = try controller.reference()
            try #require(reference.processIdentifier == ProcessInfo.processInfo.processIdentifier)
            try #require(reference.windowNumber == window.windowNumber)
            _ = try await controller.perform(request, at: screenPoint, reference: reference)
        }
        #expect(receiver.leftClicks == 3)
        #expect(receiver.maximumClickCount == 2)
        #expect(receiver.rightClicks == 1)
        #expect(receiver.scrollEvents > 0)
        #expect(receiver.receivedPoints.allSatisfy { receiver.bounds.contains($0) })
        let request = try #require(ScreenOperationPolicy.request(for: "帮我把这个窗口关掉"))
        try #require(request.kind == .closeWindow)
        _ = try controller.closeFrontWindow()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!window.isVisible)
        UserDefaults.standard.set(false, forKey: ScreenOperationPolicy.preferenceKey)
        let eventCount = receiver.receivedPoints.count
        do {
            _ = try await controller.perform(.init(kind: .click, target: "测试区域"), at: screenPoint,
                reference: .init(processIdentifier: ProcessInfo.processInfo.processIdentifier, windowNumber: window.windowNumber, cursorLocation: screenPoint))
            Issue.record("Disabled control dispatched a mouse action.")
        } catch { #expect(error.localizedDescription == ScreenOperationPolicy.disabledMessage) }
        #expect(receiver.receivedPoints.count == eventCount)
        UserDefaults.standard.set(true, forKey: ScreenOperationPolicy.preferenceKey)
        let cancelledAction = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await controller.perform(.init(kind: .click, target: "测试区域"), at: screenPoint,
                reference: .init(processIdentifier: ProcessInfo.processInfo.processIdentifier, windowNumber: window.windowNumber, cursorLocation: screenPoint))
        }
        do {
            _ = try await cancelledAction.value
            Issue.record("A cancelled action dispatched a mouse event.")
        } catch { #expect(error is CancellationError) }
        #expect(receiver.receivedPoints.count == eventCount)
    }

    @Test func naturalImperativesAuthorizeExactlyOneOperation() {
        #expect(ScreenOperationPolicy.request(for: "帮我点击 Export CSV 按钮") == .init(kind: .click, target: "export csv 按钮"))
        #expect(ScreenOperationPolicy.request(for: "双击打开报告文件")?.kind == .doubleClick)
        #expect(ScreenOperationPolicy.request(for: "右键那个文件")?.kind == .rightClick)
        #expect(ScreenOperationPolicy.request(for: "向下滚动一点")?.kind == .scrollDown)
        #expect(ScreenOperationPolicy.request(for: "往上翻一页")?.kind == .scrollUp)
        #expect(ScreenOperationPolicy.request(for: "打开 Chrome")?.kind == .openApplication)
        #expect(ScreenOperationPolicy.request(for: "打开这个菜单")?.kind == .click)
        #expect(ScreenOperationPolicy.request(for: "点开这个链接")?.kind == .click)
        #expect(ScreenOperationPolicy.request(for: "停止操作")?.kind == .cancel)
    }

    @Test func guidanceAndNegatedCommandsNeverAuthorizeClicks() {
        for prompt in ["指一下 Export CSV 按钮", "你指给我", "怎么点击这个按钮", "点哪个比较好", "不要点击 Save", "双击是什么意思", "帮我写代码", "你好"] {
            #expect(ScreenOperationPolicy.request(for: prompt) == nil)
        }
    }

    @Test func operationFollowUpsKeepIdentityButFreshNamedTargetsStayIndependent() {
        #expect(ScreenOperationPolicy.request(for: "点它")?.requiresConversationContext == true)
        #expect(ScreenOperationPolicy.request(for: "打开那个")?.requiresConversationContext == true)
        #expect(ScreenOperationPolicy.request(for: "点击刚才那个按钮")?.requiresConversationContext == true)
        #expect(ScreenOperationPolicy.request(for: "点击 Export CSV 按钮")?.requiresConversationContext == false)
    }

    @Test func explicitTargetsAreNotFilteredByRiskWordsOrApplicationName() {
        for target in ["删除", "付款", "发送", "确定", "继续", "OK", "Confirm", "Codex", "系统设置", "Dock"] {
            #expect(ScreenOperationPolicy.request(for: "点击\(target)")?.kind == .click)
        }
        #expect(ScreenOperationPolicy.request(for: "能不能帮我点一下确定按钮")?.kind == .click)
        #expect(ScreenOperationPolicy.request(for: "你可以帮我关闭当前窗口吗")?.kind == .closeWindow)
        #expect(ScreenOperationPolicy.request(for: "帮我把这个窗口关掉")?.kind == .closeWindow)
        #expect(ScreenOperationPolicy.request(for: "打开微信")?.kind == .openApplication)
        #expect(ScreenOperationPolicy.request(for: "打开 Codex")?.kind == .openApplication)
        #expect(!ScreenOperationPolicy.containsMultipleOperations("点击同时播放按钮"))
        #expect(ScreenOperationPolicy.containsMultipleOperations("点击保存然后关闭窗口"))
    }

    @Test func operationsDefaultOffAndSettingPersistsWithoutChangingConversationPolicy() {
        let previous = UserDefaults.standard.object(forKey: ScreenOperationPolicy.preferenceKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: ScreenOperationPolicy.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: ScreenOperationPolicy.preferenceKey) }
        }
        UserDefaults.standard.removeObject(forKey: ScreenOperationPolicy.preferenceKey)
        let manager = CompanionManager()
        #expect(!manager.isScreenOperationsEnabled)
        manager.setScreenOperationsEnabled(true)
        #expect(UserDefaults.standard.bool(forKey: ScreenOperationPolicy.preferenceKey))
        let relaunchedManager = CompanionManager()
        #expect(relaunchedManager.isScreenOperationsEnabled)
        #expect(relaunchedManager.lastScreenOperationMessage.contains("已开启"))
        manager.setScreenOperationsEnabled(false)
        #expect(!manager.isScreenOperationsEnabled)
        #expect(manager.lastScreenOperationMessage.contains("关闭"))
        #expect(ScreenOperationPolicy.disabledMessage.contains("这次没有操作"))
    }

    @Test func confirmationOnlyInterpretsAnAnswerWithoutInventingAnAction() {
        #expect(ScreenOperationPolicy.confirmationDecision(for: "是的") == true)
        #expect(ScreenOperationPolicy.confirmationDecision(for: "不是") == false)
        #expect(ScreenOperationPolicy.confirmationDecision(for: "你好") == nil)
        #expect(ScreenOperationPolicy.request(for: "是的") == nil)
        #expect(ScreenOperationPolicy.request(for: "确定") == nil)
    }

    @Test func disabledNativeExecutorRejectsBothClicksAndAppLaunchBeforeAnySideEffect() async {
        let previous = UserDefaults.standard.object(forKey: ScreenOperationPolicy.preferenceKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: ScreenOperationPolicy.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: ScreenOperationPolicy.preferenceKey) }
        }
        UserDefaults.standard.set(false, forKey: ScreenOperationPolicy.preferenceKey)
        let controller = ScreenOperationController()
        do {
            _ = try await controller.perform(.init(kind: .click, target: "Single Click"), at: .zero,
                reference: .init(processIdentifier: 0, windowNumber: 0, cursorLocation: .zero))
            Issue.record("A disabled executor must not accept a click.")
        } catch { #expect(error.localizedDescription == ScreenOperationPolicy.disabledMessage) }
        do {
            _ = try await controller.openApplication(named: "Chrome")
            Issue.record("A disabled executor must not launch an app.")
        } catch { #expect(error.localizedDescription == ScreenOperationPolicy.disabledMessage) }
        do {
            _ = try controller.closeFrontWindow()
            Issue.record("A disabled executor must not close a window.")
        } catch { #expect(error.localizedDescription == ScreenOperationPolicy.disabledMessage) }
    }

    @Test func quartzConversionPreservesPrimaryAndSecondaryDisplayCoordinates() {
        #expect(ScreenOperationController.quartzPoint(fromAppKit: CGPoint(x: 100, y: 900), primaryDisplayHeight: 1080) == CGPoint(x: 100, y: 180))
        #expect(ScreenOperationController.quartzPoint(fromAppKit: CGPoint(x: -500, y: -200), primaryDisplayHeight: 1080) == CGPoint(x: -500, y: 1280))
    }

    @Test func changedOrInvalidTargetPixelsRejectStaleGeometry() throws {
        func bitmap(_ color: NSColor) throws -> Data {
            let image = NSImage(size: CGSize(width: 100, height: 100))
            image.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 100, height: 100).fill(); image.unlockFocus()
            return try #require(image.tiffRepresentation)
        }
        let white = try bitmap(.white), red = try bitmap(.red)
        #expect(ScreenOperationController.targetPatchDifference(original: white, current: white, normalizedPoint: CGPoint(x: 500, y: 500)) == 0)
        #expect(try #require(ScreenOperationController.targetPatchDifference(original: white, current: red, normalizedPoint: CGPoint(x: 500, y: 500))) > 12)
        #expect(ScreenOperationController.targetPatchDifference(original: Data(), current: red, normalizedPoint: CGPoint(x: 500, y: 500)) == nil)
    }
}

@MainActor
private final class NativeOperationEventReceiver: NSView {
    var leftClicks = 0
    var maximumClickCount = 0
    var rightClicks = 0
    var scrollEvents = 0
    var receivedPoints: [CGPoint] = []

    override func mouseDown(with event: NSEvent) {
        leftClicks += 1
        maximumClickCount = max(maximumClickCount, event.clickCount)
        receivedPoints.append(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        rightClicks += 1
        receivedPoints.append(convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        scrollEvents += 1
        receivedPoints.append(convert(event.locationInWindow, from: nil))
    }
}
