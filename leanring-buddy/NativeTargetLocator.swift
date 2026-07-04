//
//  NativeTargetLocator.swift
//  leanring-buddy
//
//  Uses macOS system metadata to locate common visible targets without asking
//  the vision model to guess pixel coordinates.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct NativePointingTarget {
    let screenLocation: CGPoint
    let displayFrame: CGRect
    let label: String
    let source: String
}

enum NativeTargetLocator {
    private struct AppTarget {
        let label: String
        let aliases: [String]
        let bundleIdentifiers: [String]
        let ownerNames: [String]
        let dockTitles: [String]
    }

    private static let appTargets: [AppTarget] = [
        AppTarget(
            label: "Google Chrome",
            aliases: ["google chrome", "chrome", "谷歌浏览器", "谷歌", "浏览器"],
            bundleIdentifiers: ["com.google.Chrome"],
            ownerNames: ["Google Chrome"],
            dockTitles: ["Google Chrome"]
        ),
        AppTarget(
            label: "Safari",
            aliases: ["safari", "苹果浏览器"],
            bundleIdentifiers: ["com.apple.Safari"],
            ownerNames: ["Safari"],
            dockTitles: ["Safari"]
        ),
        AppTarget(
            label: "Finder",
            aliases: ["finder", "访达", "文件管理器"],
            bundleIdentifiers: ["com.apple.finder"],
            ownerNames: ["Finder"],
            dockTitles: ["Finder", "访达"]
        ),
        AppTarget(
            label: "Xcode",
            aliases: ["xcode"],
            bundleIdentifiers: ["com.apple.dt.Xcode"],
            ownerNames: ["Xcode"],
            dockTitles: ["Xcode"]
        ),
        AppTarget(
            label: "Terminal",
            aliases: ["terminal", "终端"],
            bundleIdentifiers: ["com.apple.Terminal"],
            ownerNames: ["Terminal"],
            dockTitles: ["Terminal", "终端"]
        ),
        AppTarget(
            label: "iTerm",
            aliases: ["iterm", "iterm2"],
            bundleIdentifiers: ["com.googlecode.iterm2"],
            ownerNames: ["iTerm2"],
            dockTitles: ["iTerm", "iTerm2"]
        ),
        AppTarget(
            label: "Cursor",
            aliases: ["cursor"],
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            ownerNames: ["Cursor"],
            dockTitles: ["Cursor"]
        ),
        AppTarget(
            label: "Visual Studio Code",
            aliases: ["visual studio code", "vscode", "vs code"],
            bundleIdentifiers: ["com.microsoft.VSCode"],
            ownerNames: ["Code", "Visual Studio Code"],
            dockTitles: ["Visual Studio Code", "Code"]
        ),
        AppTarget(
            label: "Godot",
            aliases: ["godot"],
            bundleIdentifiers: ["org.godotengine.godot", "org.godotengine.godot4"],
            ownerNames: ["Godot"],
            dockTitles: ["Godot"]
        )
    ]

    static func locate(transcript: String, assistantResponse: String) -> NativePointingTarget? {
        let combinedText = normalize("\(transcript) \(assistantResponse)")

        if let desktopTarget = locateDesktopItem(in: combinedText) {
            clickyDebugLog("native locator target label=\(desktopTarget.label) source=\(desktopTarget.source) screenLocation=\(desktopTarget.screenLocation) displayFrame=\(desktopTarget.displayFrame)")
            return desktopTarget
        }

        guard let appTarget = matchingAppTarget(in: combinedText) else {
            return nil
        }

        let wantsWindow = containsAny(combinedText, ["窗口", "window", "页面", "浏览器在哪"])
        let wantsIcon = containsAny(combinedText, ["图标", "dock", "程序坞", "app icon", "icon", "在哪"])

        let preferredSources: [() -> NativePointingTarget?]
        if wantsWindow && !wantsIcon {
            preferredSources = [
                { locateWindow(for: appTarget) },
                { locateDockItem(for: appTarget) }
            ]
        } else {
            preferredSources = [
                { locateDockItem(for: appTarget) },
                { locateWindow(for: appTarget) }
            ]
        }

        for source in preferredSources {
            if let target = source() {
                clickyDebugLog("native locator target label=\(target.label) source=\(target.source) screenLocation=\(target.screenLocation) displayFrame=\(target.displayFrame)")
                return target
            }
        }

        clickyDebugLog("native locator no-target app=\(appTarget.label)")
        return nil
    }

    private static func locateDesktopItem(in normalizedText: String) -> NativePointingTarget? {
        guard containsAny(normalizedText, ["桌面", "文件", "文件夹", "folder", "file", "定位", "在哪", "哪里", "指"]) else {
            return nil
        }

        guard let finderApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return nil
        }

        let finderElement = AXUIElementCreateApplication(finderApp.processIdentifier)
        var bestMatch: (target: NativePointingTarget, score: Int)?

        for element in descendants(of: finderElement, maxDepth: 8) {
            let role = stringAttribute(element, kAXRoleAttribute)
            guard role == "AXImage" else { continue }

            let title = stringAttribute(element, kAXTitleAttribute)
            let description = stringAttribute(element, kAXDescriptionAttribute)
            let filename = stringAttribute(element, "AXFilename")
            let names = [filename, title, description]
                .map(normalize)
                .filter { !$0.isEmpty && $0.count >= 2 }

            guard let matchedName = names.first(where: { normalizedText.contains($0) }) else {
                continue
            }

            guard let position = pointAttribute(element, kAXPositionAttribute),
                  let size = sizeAttribute(element, kAXSizeAttribute),
                  size.width > 0,
                  size.height > 0 else {
                continue
            }

            let topLeftRect = CGRect(origin: position, size: size)
            let appKitRect = appKitRectFromTopLeftGlobalRect(topLeftRect)
            let label = filename.isEmpty ? (title.isEmpty ? matchedName : title) : filename
            guard let target = targetFromAppKitRect(appKitRect, label: label, source: "desktop") else {
                continue
            }

            let score = matchedName.count
            if bestMatch == nil || score > bestMatch!.score {
                bestMatch = (target, score)
            }
        }

        return bestMatch?.target
    }

    private static func matchingAppTarget(in normalizedText: String) -> AppTarget? {
        if let directMatch = appTargets.first(where: { target in
            target.aliases.contains { normalizedText.contains(normalize($0)) }
        }) {
            return directMatch
        }

        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            guard let appName = app.localizedName, appName.count > 2 else { continue }
            if normalizedText.contains(normalize(appName)) {
                return AppTarget(
                    label: appName,
                    aliases: [appName],
                    bundleIdentifiers: [app.bundleIdentifier].compactMap { $0 },
                    ownerNames: [appName],
                    dockTitles: [appName]
                )
            }
        }

        return nil
    }

    private static func locateDockItem(for target: AppTarget) -> NativePointingTarget? {
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }

        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
        for element in descendants(of: dockElement, maxDepth: 3) {
            let role = stringAttribute(element, kAXRoleAttribute)
            guard role == "AXDockItem" else { continue }

            let title = stringAttribute(element, kAXTitleAttribute)
            let description = stringAttribute(element, kAXDescriptionAttribute)
            let searchableText = normalize("\(title) \(description)")
            guard target.dockTitles.contains(where: { searchableText.contains(normalize($0)) }) else {
                continue
            }

            guard let position = pointAttribute(element, kAXPositionAttribute),
                  let size = sizeAttribute(element, kAXSizeAttribute) else {
                continue
            }

            let topLeftRect = CGRect(origin: position, size: size)
            let appKitRect = appKitRectFromTopLeftGlobalRect(topLeftRect)
            return targetFromAppKitRect(
                appKitRect,
                label: "\(target.label) 图标",
                source: "dock"
            )
        }

        return nil
    }

    private static func locateWindow(for target: AppTarget) -> NativePointingTarget? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            let layer = window[kCGWindowLayer as String] as? Int ?? Int.max
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 0
            guard layer == 0, alpha > 0 else { continue }

            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            let normalizedOwnerName = normalize(ownerName)
            guard target.ownerNames.contains(where: { normalizedOwnerName.contains(normalize($0)) }) else {
                continue
            }

            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = number(bounds["X"]),
                  let y = number(bounds["Y"]),
                  let width = number(bounds["Width"]),
                  let height = number(bounds["Height"]),
                  width >= 40,
                  height >= 40 else {
                continue
            }

            let topLeftRect = CGRect(x: x, y: y, width: width, height: height)
            let appKitRect = appKitRectFromTopLeftGlobalRect(topLeftRect)
            let title = window[kCGWindowName as String] as? String
            return targetFromAppKitRect(
                appKitRect,
                label: title?.isEmpty == false ? "\(target.label) 窗口" : target.label,
                source: "window"
            )
        }

        return nil
    }

    private static func targetFromAppKitRect(
        _ rect: CGRect,
        label: String,
        source: String
    ) -> NativePointingTarget? {
        guard rect.width > 0, rect.height > 0 else { return nil }

        let targetPoint: CGPoint
        if source == "window" {
            targetPoint = CGPoint(x: rect.midX, y: rect.maxY - min(28, rect.height / 2))
        } else {
            targetPoint = CGPoint(x: rect.midX, y: rect.midY)
        }

        let displayFrame = displayFrame(containing: targetPoint)
        return NativePointingTarget(
            screenLocation: targetPoint,
            displayFrame: displayFrame,
            label: label,
            source: source
        )
    }

    private static func descendants(of element: AXUIElement, maxDepth: Int) -> [AXUIElement] {
        guard maxDepth >= 0 else { return [] }

        var result: [AXUIElement] = []
        for child in children(of: element) {
            result.append(child)
            result.append(contentsOf: descendants(of: child, maxDepth: maxDepth - 1))
        }
        return result
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard error == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return "" }
        return value as? String ?? ""
    }

    private static func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue((axValue as! AXValue), .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private static func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue((axValue as! AXValue), .cgSize, &size) else {
            return nil
        }
        return size
    }

    private static func appKitRectFromTopLeftGlobalRect(_ rect: CGRect) -> CGRect {
        let desktopTop = NSScreen.screens.map { $0.frame.maxY }.max()
            ?? NSScreen.main?.frame.maxY
            ?? rect.maxY

        return CGRect(
            x: rect.origin.x,
            y: desktopTop - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private static func displayFrame(containing point: CGPoint) -> CGRect {
        if let containingScreen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return containingScreen.frame
        }

        return NSScreen.screens.min { lhs, rhs in
            distanceSquared(from: lhs.frame.center, to: point) < distanceSquared(from: rhs.frame.center, to: point)
        }?.frame ?? NSScreen.main?.frame ?? .zero
    }

    private static func distanceSquared(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func number(_ value: Any?) -> CGFloat? {
        if let number = value as? NSNumber {
            return CGFloat(number.doubleValue)
        }
        if let double = value as? Double {
            return CGFloat(double)
        }
        if let int = value as? Int {
            return CGFloat(int)
        }
        return nil
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains(normalize($0)) }
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
