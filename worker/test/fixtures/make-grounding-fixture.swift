import AppKit

// Deterministic screenshot surrogate: top-left coordinates and exact target
// rectangles let the live model test measure hits rather than trusting its prose.
let width = 1440
let height = 900
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

func rectangle(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: NSColor, radius: CGFloat = 0) {
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: 900 - y - height, width: width, height: height),
        xRadius: radius, yRadius: radius).fill()
}
func label(_ text: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 14, color: NSColor = .labelColor) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color]
    (text as NSString).draw(at: NSPoint(x: x, y: 900 - y - size - 5), withAttributes: attributes)
}

rectangle(0, 0, 1440, 900, NSColor(calibratedRed: 0.32, green: 0.40, blue: 0.55, alpha: 1))
rectangle(0, 0, 1440, 26, NSColor(calibratedWhite: 0.90, alpha: 1))
label("●   Studio Notes     File     Edit     View     Window     Help", 18, 2, size: 13, color: .black)
label("85%    Wi-Fi    Tue 10:20", 1230, 2, size: 12, color: .black)
rectangle(80, 90, 1210, 730, .white, radius: 12)
rectangle(80, 90, 1210, 66, NSColor(calibratedWhite: 0.94, alpha: 1), radius: 12)
for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
    rectangle(CGFloat(98 + index * 22), 106, 14, 14, color, radius: 7)
}
label("Project Atlas — Notes", 510, 105, size: 18, color: .black)
rectangle(1160, 105, 90, 32, .systemBlue, radius: 6)
label("Save", 1188, 109, size: 15, color: .white)
rectangle(80, 156, 218, 664, NSColor(calibratedWhite: 0.96, alpha: 1))
label("WORKSPACE", 100, 184, size: 11, color: .gray)
label("Overview", 112, 223, size: 15, color: .black)
rectangle(96, 270, 186, 36, NSColor(calibratedRed: 0.81, green: 0.88, blue: 0.99, alpha: 1), radius: 6)
label("Documents", 112, 278, size: 15, color: .black)
label("Archive", 112, 326, size: 15, color: .black)
label("Settings", 112, 752, size: 15, color: .black)
label("Project checklist", 340, 195, size: 26, color: .black)
label("Two actions have similar names. Locate the requested one, not its neighbor.", 340, 240, size: 15, color: .darkGray)
rectangle(340, 315, 530, 46, NSColor(calibratedWhite: 0.94, alpha: 1), radius: 6)
label("Search notes...", 360, 326, size: 15, color: .gray)
rectangle(340, 420, 120, 38, .systemBlue, radius: 6)
label("Export PDF", 357, 429, size: 14, color: .white)
rectangle(480, 420, 120, 38, .systemGray, radius: 6)
label("Export CSV", 497, 429, size: 14, color: .white)
label("Last edited today. All changes saved locally.", 340, 515, size: 14, color: .darkGray)
rectangle(1140, 734, 110, 36, .systemRed, radius: 6)
label("Delete note", 1154, 742, size: 14, color: .white)
rectangle(1330, 180, 56, 46, .systemCyan, radius: 6)
rectangle(1330, 171, 26, 15, .systemCyan, radius: 4)
label("Research", 1328, 237, size: 13, color: .white)
NSGraphicsContext.restoreGraphicsState()
let outputPath = CommandLine.arguments[1]
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outputPath))
