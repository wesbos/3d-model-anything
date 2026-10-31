// Run from apps/house-capture: swift release/generate-dev-icon.swift
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.035, green: 0.13, blue: 0.32, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
func polygon(_ points: [CGPoint], _ color: CGColor) {
    context.beginPath()
    context.move(to: points[0])
    for point in points.dropFirst() { context.addLine(to: point) }
    context.closePath()
    context.setFillColor(color)
    context.fillPath()
}
let top = CGPoint(x: 512, y: 868)
let left = CGPoint(x: 242, y: 724)
let center = CGPoint(x: 512, y: 580)
let right = CGPoint(x: 782, y: 724)
let bottom = CGPoint(x: 512, y: 314)
polygon([top, right, center, left], CGColor(red: 0.55, green: 0.93, blue: 1, alpha: 1))
polygon([left, center, bottom, CGPoint(x: 242, y: 458)], CGColor(red: 0.12, green: 0.65, blue: 0.96, alpha: 1))
polygon([center, right, CGPoint(x: 782, y: 458), bottom], CGColor(red: 0.08, green: 0.39, blue: 0.86, alpha: 1))
let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo-Bold" as CFString, 158, nil),
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "DEV", attributes: attributes))
let width = CTLineGetTypographicBounds(line, nil, nil, nil)
context.textPosition = CGPoint(x: (1024 - width) / 2, y: 130)
CTLineDraw(line, context)
let output = URL(fileURLWithPath: "HouseCapture/Assets.xcassets/AppIconDev.appiconset/AppIcon.png")
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination), "Unable to save development icon")
