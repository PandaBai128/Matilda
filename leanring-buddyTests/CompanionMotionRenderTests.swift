import AppKit
import SwiftUI
import Testing
@testable import Matilda

struct CompanionMotionRenderTests {
    @Test @MainActor func idleAvatarActuallyBlinksAndReopens() async throws {
        let host = NSHostingView(rootView: ZhuangzhuangAvatarView(
            diameter: 64, voiceState: .idle, navigationMode: .followingCursor,
            audioPowerLevel: 0, travelTiltDegrees: 0, glowColor: .clear,
            glowIntensity: 0, isGlowEnabled: false
        ).frame(width: 100, height: 100).background(Color.black))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(300))
        func pixels() throws -> Data {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return try #require(rep.representation(using: .png, properties: [:]))
        }
        let openEyes = try pixels()
        var closedEyes: Data?
        var reopened = false
        let deadline = Date().addingTimeInterval(3.5)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(40))
            let current = try pixels()
            if current != openEyes { closedEyes = current }
            if closedEyes != nil && current == openEyes { reopened = true; break }
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(closedEyes == nil, "Reduce Motion must keep the idle portrait still.")
        } else {
            #expect(closedEyes != nil, "The live idle view must render its first blink before auto-hide.")
            #expect(reopened, "The live idle view must reopen its eyes after the short blink.")
        }
    }

    @Test @MainActor func livingAvatarRendersAtActualSizesOnBothBackgrounds() throws {
        let renderer = ImageRenderer(content:
            VStack(spacing: 0) {
                ForEach([false, true], id: \.self) { lightBackground in
                    VStack(spacing: 24) {
                        ForEach(CompanionVisualStyle.allCases, id: \.self) { style in
                            HStack(spacing: 36) {
                                ForEach(0..<3) { stateIndex in
                                    let state: CompanionVoiceState = [.idle, .listening, .processing][stateIndex]
                                    ZhuangzhuangAvatarView(
                                        diameter: 42, voiceState: state, navigationMode: .followingCursor,
                                        audioPowerLevel: 0.55, travelTiltDegrees: 0,
                                        glowColor: .blue, glowIntensity: 0, isGlowEnabled: false,
                                        visualStyle: style
                                    ).frame(width: 86, height: 86)
                                }
                            }
                        }
                    }.padding(24).background(lightBackground ? Color.white : Color(red: 0.06, green: 0.08, blue: 0.07))
                }
            }
        )
        renderer.scale = 2
        let cgImage = try #require(renderer.cgImage)
        let png = try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MatildaMotionReview", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("LivingAvatar.png"))
    }

    @Test @MainActor func bundledPoseAtlasesRenderForVisualReview() throws {
        for (name, columns, rows) in [("ZhuangzhuangHeadAtlas", 3, 2), ("ZhuangzhuangBodyAtlas", 2, 2)] {
            let image = try #require(NSImage(named: name))
            #expect(image.size.width > 0 && image.size.height > 0)
            let renderer = ImageRenderer(content:
                VStack(spacing: 20) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 20) {
                            ForEach(0..<columns, id: \.self) { column in
                                CompanionAtlasFrame(name: name, columns: columns, rows: rows, index: row * columns + column, size: 160)
                                    .background(Color(red: 0.06, green: 0.08, blue: 0.07))
                            }
                        }
                    }
                }.padding(20).background(Color(red: 0.15, green: 0.17, blue: 0.16))
            )
            renderer.scale = 2
            let cgImage = try #require(renderer.cgImage)
            #expect(cgImage.width > 500)
            let png = try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
            let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MatildaMotionReview", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent(name + ".png"))
            print("Matilda motion render: \(folder.path)/\(name).png")
        }
    }
}
