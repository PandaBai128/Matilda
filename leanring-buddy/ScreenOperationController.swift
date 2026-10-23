import AppKit
import ApplicationServices
import ImageIO

struct ScreenOperationReference {
    let processIdentifier: pid_t
    let windowNumber: Int
    let cursorLocation: CGPoint
}

enum ScreenOperationError: LocalizedError {
    case unsafe(String)
    var errorDescription: String? { if case let .unsafe(message) = self { return message }; return nil }
}

@MainActor
final class ScreenOperationController {
    func reference() throws -> ScreenOperationReference {
        try assertEnabled()
        guard AXIsProcessTrusted(), let application = NSWorkspace.shared.frontmostApplication else {
            throw ScreenOperationError.unsafe("系统辅助功能权限尚未生效。")
        }
        let number = frontWindow(processIdentifier: application.processIdentifier)?[kCGWindowNumber as String] as? Int ?? 0
        return .init(processIdentifier: application.processIdentifier, windowNumber: number, cursorLocation: NSEvent.mouseLocation)
    }

    func assertExecutionAllowed() throws {
        try assertEnabled()
        try Task.checkCancellation()
        let flags = CGEventSource.flagsState(.combinedSessionState)
        if flags.contains(.maskControl) && flags.contains(.maskAlternate) { throw CancellationError() }
    }

    func sceneHasChanged(since reference: ScreenOperationReference) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier != reference.processIdentifier
            || (reference.windowNumber != 0 && frontWindow(processIdentifier: reference.processIdentifier)?[kCGWindowNumber as String] as? Int != reference.windowNumber)
    }

    func applicationURL(named name: String) -> URL? {
        if let identifier = ScreenOperationPolicy.applicationBundleIdentifier(named: name),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return url }
        let normalizedName = name.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".app", with: "")
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var matches: [URL] = []
        for root in roots {
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in entries where url.pathExtension == "app" {
                let bundle = Bundle(url: url)
                let names = [url.deletingPathExtension().lastPathComponent, bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String].compactMap { $0 }
                if names.contains(where: { $0.lowercased().replacingOccurrences(of: " ", with: "") == normalizedName }) { matches.append(url) }
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    func closeFrontWindow() throws -> String {
        try assertExecutionAllowed()
        guard let application = NSWorkspace.shared.frontmostApplication else { throw ScreenOperationError.unsafe("你要关闭哪个窗口？") }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.5)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let focusedWindow, CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() else { throw ScreenOperationError.unsafe("你要关闭哪个窗口？请说一下窗口名字。") }
        let window = unsafeBitCast(focusedWindow, to: AXUIElement.self)
        var closeButton: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButton) == .success,
              let closeButton, CFGetTypeID(closeButton) == AXUIElementGetTypeID() else { throw ScreenOperationError.unsafe("这个窗口的关闭位置在哪里？请再描述一下。") }
        try assertExecutionAllowed()
        guard AXUIElementPerformAction(unsafeBitCast(closeButton, to: AXUIElement.self), kAXPressAction as CFString) == .success else {
            throw ScreenOperationError.unsafe("系统没有完成这次关闭操作。")
        }
        return "已点击当前窗口的关闭按钮。"
    }

    func openApplication(named name: String) async throws -> String {
        try assertEnabled()
        try Task.checkCancellation()
        guard let url = applicationURL(named: name) else {
            throw ScreenOperationError.unsafe("你要打开哪个应用？请说一下它的完整名字。")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try await Task.sleep(for: .milliseconds(250))
        try Task.checkCancellation()
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
            ? "已打开\(name)。" : "已经请求打开\(name)，但还没有确认它来到前台。"
    }

    func perform(_ request: ScreenOperationRequest, at appKitPoint: CGPoint, reference: ScreenOperationReference) async throws -> String {
        try assertExecutionAllowed()
        let point = Self.quartzPoint(fromAppKit: appKitPoint, primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
        guard NSScreen.screens.contains(where: { $0.frame.contains(appKitPoint) }) else { throw ScreenOperationError.unsafe("目标不在当前屏幕上，你要点哪里？") }
        let element = element(at: point)
        let before = element.map { state(of: $0) }
        try Task.checkCancellation()
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ScreenOperationError.unsafe("无法创建鼠标事件，没有操作。")
        }
        if request.kind == .scrollUp || request.kind == .scrollDown {
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                      wheel1: request.kind == .scrollUp ? 400 : -400, wheel2: 0, wheel3: 0) else {
                throw ScreenOperationError.unsafe("无法创建滚动事件，没有操作。")
            }
            event.location = point
            try assertExecutionAllowed()
            event.post(tap: .cghidEventTap)
        } else {
            let right = request.kind == .rightClick
            let count = request.kind == .doubleClick ? 2 : 1
            // Prepare every event before posting any, then complete each down/up
            // pair synchronously so cancellation can never leave a button held.
            var events: [CGEvent] = []
            for clickIndex in 1...count {
                let eventTypes: [CGEventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
                for type in eventTypes {
                    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: right ? .right : .left) else {
                        throw ScreenOperationError.unsafe("无法创建点击事件，没有点击。")
                    }
                    event.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
                    events.append(event)
                }
            }
            try assertExecutionAllowed()
            events.forEach { $0.post(tap: .cghidEventTap) }
        }
        try await Task.sleep(for: .milliseconds(350))
        try Task.checkCancellation()
        let changed = element.map { state(of: $0) } != before || NSWorkspace.shared.frontmostApplication?.processIdentifier != reference.processIdentifier
            || frontWindow(processIdentifier: reference.processIdentifier)?[kCGWindowNumber as String] as? Int != reference.windowNumber
        let verb: String
        switch request.kind {
        case .doubleClick: verb = "已双击"
        case .rightClick: verb = "已右键点击"
        case .scrollUp: verb = "已向上滚动"
        case .scrollDown: verb = "已向下滚动"
        default: verb = "已单击"
        }
        return changed ? "\(verb)，检测到界面状态变化。" : "\(verb)。还没确认到结果变化，我没有继续操作。"
    }

    func scrollPoint(reference: ScreenOperationReference) throws -> CGPoint {
        try assertExecutionAllowed()
        let cursorQuartz = Self.quartzPoint(fromAppKit: reference.cursorLocation, primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
        if element(at: cursorQuartz) != nil {
            return reference.cursorLocation
        }
        guard let window = frontWindow(processIdentifier: reference.processIdentifier),
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rectangle = CGRect(dictionaryRepresentation: bounds) else {
            throw ScreenOperationError.unsafe("没有确认到滚动区域。")
        }
        return .init(x: rectangle.midX, y: CGDisplayBounds(CGMainDisplayID()).height - rectangle.midY)
    }

    private func frontWindow(processIdentifier: pid_t) -> [String: Any]? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        if processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // Match the actual key window, not an auxiliary sharing/SwiftUI window.
            guard let keyWindowNumber = NSApp.keyWindow?.windowNumber else { return nil }
            return windows.first { ($0[kCGWindowNumber as String] as? Int) == keyWindowNumber
                && ($0[kCGWindowOwnerPID as String] as? Int) == Int(processIdentifier) }
        }
        return windows.first { ($0[kCGWindowOwnerPID as String] as? Int) == Int(processIdentifier) && ($0[kCGWindowLayer as String] as? Int) == 0 }
    }

    private func assertEnabled() throws {
        guard UserDefaults.standard.bool(forKey: ScreenOperationPolicy.preferenceKey) else {
            throw ScreenOperationError.unsafe(ScreenOperationPolicy.disabledMessage)
        }
    }

    private func element(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.1)
        return element
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private func state(of element: AXUIElement) -> String {
        [kAXValueAttribute, kAXFocusedAttribute, kAXSelectedAttribute, kAXExpandedAttribute, kAXTitleAttribute]
            .map { attribute(element, $0) }.joined(separator: "|")
    }

    nonisolated static func quartzPoint(fromAppKit point: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
        .init(x: point.x, y: primaryDisplayHeight - point.y)
    }

    nonisolated static func targetPatchDifference(original: Data, current: Data, normalizedPoint: CGPoint) -> Double? {
        func pixels(_ data: Data) -> [UInt8]? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let centerX = normalizedPoint.x / 1000 * CGFloat(image.width), centerY = normalizedPoint.y / 1000 * CGFloat(image.height)
            let patch = CGRect(x: centerX - 24, y: centerY - 24, width: 48, height: 48).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let cropped = image.cropping(to: patch), patch.width > 8, patch.height > 8 else { return nil }
            var data = [UInt8](repeating: 0, count: 32 * 32 * 4)
            let rendered = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(cropped, in: CGRect(x: 0, y: 0, width: 32, height: 32)); return true
            }
            return rendered ? data : nil
        }
        guard let first = pixels(original), let second = pixels(current) else { return nil }
        let total = zip(first, second).enumerated().filter { $0.offset % 4 != 3 }.reduce(0.0) { $0 + Double(abs(Int($1.element.0) - Int($1.element.1))) }
        return total / Double(32 * 32 * 3)
    }
}
