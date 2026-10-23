import AppKit

// Isolated, non-destructive click target. It displays only sanitized test images
// and records native mouse events; no webpage, browser, network or OS action runs.
final class ReplayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ReplayView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    let folder: String
    let names = ["save", "close", "csv"]
    let boxes: [String: CGRect] = [
        "save": CGRect(x: 1663, y: 631, width: 85, height: 41),
        "close": CGRect(x: 412, y: 643, width: 18, height: 18),
        "csv": CGRect(x: 760, y: 911, width: 124, height: 46)
    ]
    var index = 0
    var marker: NSPoint?
    var lastHit = false
    var clickCount = 0
    var records: [[String: Any]] = []
    init(folder: String) {
        self.folder = folder
        super.init(frame: .zero)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "\(folder)/native-clicks.json")),
           let previous = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            records = previous
            clickCount = previous.count
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Isolated pointing replay. Keys 1 Save, 2 Close, 3 CSV; P dispatches the pending model mouse event inside this window only.")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        if let image = NSImage(contentsOfFile: "\(folder)/\(names[index]).png") {
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
        if let marker {
            (lastHit ? NSColor.systemGreen : NSColor.systemRed).setStroke()
            let circle = NSBezierPath(ovalIn: NSRect(x: marker.x - 5, y: marker.y - 5, width: 10, height: 10))
            circle.lineWidth = 2
            circle.stroke()
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.characters?.lowercased() == "p" {
            dispatchPendingModelPoint()
            return
        }
        if let character = event.characters, let number = Int(character), (1...3).contains(number) {
            index = number - 1
            marker = nil
            window?.title = "Replay \(names[index]) ready; clicks \(clickCount)"
            setAccessibilityValue("\(names[index]) ready")
            needsDisplay = true
        } else { super.keyDown(with: event) }
    }
    private func dispatchPendingModelPoint() {
        guard let window,
              let data = try? Data(contentsOf: URL(fileURLWithPath: "\(folder)/native-pending.json")),
              let point = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = point["x"], let y = point["y"], let width = point["width"], let height = point["height"],
              width > 0, height > 0 else { return }
        let contentCoordinates = point["contentCoordinates"] == 1
        let location = NSPoint(x: x / width * (contentCoordinates ? bounds.width : window.frame.width),
                               y: (1 - y / height) * (contentCoordinates ? bounds.height : window.frame.height))
        // Deliberately restricted to the test window. No CGEvent, OS-wide mouse
        // movement, accessibility permission, browser or business app is involved.
        guard location.x >= 0, location.x <= bounds.width,
              location.y >= 0, location.y <= bounds.height else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let mouse = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: clickCount + 1, clickCount: 1, pressure: 1) {
                NSApp.sendEvent(mouse)
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let imagePoint = NSPoint(x: localPoint.x / bounds.width * 1920,
                                 y: localPoint.y / bounds.height * 1295)
        let name = names[index]
        var expected = boxes[name]!
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "\(folder)/expected-boxes.json")),
           let custom = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]],
           let rectangle = custom[name], rectangle.count == 4 {
            expected = CGRect(x: rectangle[0], y: rectangle[1], width: rectangle[2] - rectangle[0], height: rectangle[3] - rectangle[1])
        }
        lastHit = expected.contains(imagePoint)
        if name == "close" {
            lastHit = hypot(imagePoint.x - expected.midX, imagePoint.y - expected.midY) <= min(expected.width, expected.height) / 2
        }
        marker = localPoint
        clickCount += 1
        let scenario = (try? String(contentsOfFile: "\(folder)/variant-name.txt", encoding: .utf8)) ?? name
        let record: [String: Any] = ["case": name, "scenario": scenario, "hit": lastHit,
            "x": imagePoint.x, "y": imagePoint.y,
            "viewWidth": bounds.width, "viewHeight": bounds.height,
            "nativeClick": clickCount, "time": Date().timeIntervalSince1970]
        records.append(record)
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "\(folder)/native-clicks.json"), options: .atomic)
        }
        let outcome = lastHit ? "HIT" : "MISS"
        window?.title = "Replay \(name) \(outcome); clicks \(clickCount)"
        setAccessibilityValue("\(name) \(outcome), native click \(clickCount)")
        needsDisplay = true
    }
}

final class ReplayDelegate: NSObject, NSApplicationDelegate {
    var window: ReplayWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let folder = Bundle.main.object(forInfoDictionaryKey: "ReplayImageFolder") as! String
        window = ReplayWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1100 * 1295 / 1920),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Replay save ready; clicks 0"
        window.isReleasedWhenClosed = false
        let view = ReplayView(folder: folder)
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = ReplayDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
