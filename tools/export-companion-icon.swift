// Mechanical export of the existing neutral sprite, not a new generated portrait.
// Run from the repository root with the Xcode toolchain's swift interpreter.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("leanring-buddy/Assets.xcassets/ZhuangzhuangHeadAtlas.imageset/head-atlas.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let neutralHead = atlas.cropping(to: CGRect(x: 0, y: 0, width: atlas.width / 3, height: atlas.height / 2)) else {
    fatalError("The bundled neutral head sprite could not be loaded")
}
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                           cornerWidth: 190, cornerHeight: 190, transform: nil))
    context.fillPath()
    context.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                           cornerWidth: 190, cornerHeight: 190, transform: nil))
    context.clip()
    context.setFillColor(CGColor(red: 0.87, green: 0.92, blue: 0.98, alpha: 1))
    context.fillEllipse(in: CGRect(x: 160, y: 160, width: 704, height: 704))
    context.interpolationQuality = .high
    context.draw(neutralHead, in: CGRect(x: 75, y: 75, width: 874, height: 874))
    let destinationURL = root.appendingPathComponent("leanring-buddy/Assets.xcassets/AppIcon.appiconset/\(size)-mac.png")
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Unable to create app icon export")
    }
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}
