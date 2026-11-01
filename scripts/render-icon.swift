// render-icon.swift SVG OUT_DIR
//
// Renders the master icon SVG (docs/brand/icon.svg) to every macOS AppIcon size using only the
// system SVG renderer (AppKit's NSImage / CoreSVG) and CoreGraphics: no downloads, no fonts.
// Run through scripts/render-icon.sh, which owns the paths; this file only knows "SVG in,
// icon_<n>x<n>[@2x].png out".
//
// Output: sRGB, 8-bit RGBA, transparent outside the tile. The same input always gives the same
// pixels, so re-running the script on an unchanged SVG leaves the committed PNGs unchanged.

import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("render-icon: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: render-icon.swift SVG OUT_DIR") }
let svgPath = arguments[1]
let outDir = URL(fileURLWithPath: arguments[2], isDirectory: true)

guard let image = NSImage(contentsOfFile: svgPath),
      image.representations.contains(where: { String(describing: type(of: $0)).contains("SVG") })
else { fail("could not load \(svgPath) as an SVG image") }

guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { fail("no sRGB color space") }

func render(pixels: Int) -> CGImage {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not create a \(pixels)px bitmap context") }
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let result = context.makeImage() else { fail("could not render \(pixels)px") }
    return result
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { fail("could not create \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(url.path)") }
}

// Sanity check: the centre of the tile must be opaque and the canvas corner transparent, so a
// silently empty render (an SVG the system renderer could not draw) fails loudly.
func checkCoverage(_ image: CGImage) {
    let n = image.width
    func alpha(atX x: Int, y: Int) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { fail("could not create a probe context") }
        ctx.draw(image, in: CGRect(x: -x, y: -y, width: n, height: n))
        return pixel[3]
    }
    guard alpha(atX: n / 2, y: n / 2) == 255 else { fail("\(n)px render is not opaque at the centre") }
    guard alpha(atX: 0, y: 0) == 0 else { fail("\(n)px render is not transparent at the corner") }
}

// macOS AppIcon slots: 16, 32, 128, 256, 512 points, each at @1x and @2x.
let pointSizes = [16, 32, 128, 256, 512]
var rendered: [Int: CGImage] = [:]
for points in pointSizes {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = rendered[pixels] ?? render(pixels: pixels)
        rendered[pixels] = image
        checkCoverage(image)
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        writePNG(image, to: outDir.appendingPathComponent(name))
        print("wrote \(name) (\(pixels)px)")
    }
}
