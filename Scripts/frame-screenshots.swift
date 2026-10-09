// Frames the App Store screenshots made by `-SnazzyPro.screenshots YES`:
// each raw capture on the Ink background, with its headline in Manrope
// ExtraBold above it (docs/brand/BRAND.md), at 2880×1800 (Mac App Store, 16:10).
//
//   swift Scripts/frame-screenshots.swift [folder]
//
// folder defaults to ~/Movies/Snazzy Pro/Screenshots; it reads raw/shots.json and
// raw/*.png there and writes the framed PNGs next to raw/.
import AppKit
import CoreText
import Foundation

struct Shot: Decodable { let file: String; let headline: String; let detail: String }

let W = 2880, H = 1800
let folder = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Snazzy Pro/Screenshots")
let raw = folder.appending(path: "raw")
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }

/// Manrope from the website's font file (Core Text reads WOFF2).
func manrope(_ style: String, size: CGFloat) -> CTFont {
    guard let data = try? Data(contentsOf: repo.appending(path: "site/fonts/Manrope-Variable.woff2")),
          let all = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
          let d = all.first(where: { (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String) == "Manrope-\(style)" })
    else { fail("Can't load Manrope-\(style) from site/fonts") }
    return CTFontCreateWithFontDescriptor(d, size, nil)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// One line of text centred on x, shrunk to fit `maxWidth`.
func draw(_ text: String, style: String, size: CGFloat, color c: CGColor, baseline y: CGFloat, maxWidth: CGFloat, in ctx: CGContext) {
    var size = size
    while true {
        let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): manrope(style, size: size),
                                                    .init(kCTForegroundColorAttributeName as String): c]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        if width <= maxWidth || size < 24 {
            ctx.textPosition = CGPoint(x: (CGFloat(W) - width) / 2, y: y)
            CTLineDraw(line, ctx)
            return
        }
        size -= 2
    }
}

func frame(_ shot: Shot) throws {
    guard let source = NSImage(contentsOf: raw.appending(path: shot.file))?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fail("Can't read raw/\(shot.file)")
    }
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let full = CGRect(x: 0, y: 0, width: W, height: H)
    // Ink, with a soft Violet → Magenta glow behind the headline.
    ctx.setFillColor(color(0x0B1020))
    ctx.fill(full)
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x6C5CFF, 0.38), color(0xD946EF, 0.12), color(0x0B1020, 0)] as CFArray,
                          locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: H + 200), startRadius: 0,
                           endCenter: CGPoint(x: W / 2, y: H + 200), endRadius: 1500, options: [])

    // The headline and one line about it (Core Graphics: y goes up).
    draw(shot.headline, style: "ExtraBold", size: 124, color: color(0xFFFFFF), baseline: CGFloat(H) - 200, maxWidth: CGFloat(W) - 320, in: ctx)
    draw(shot.detail, style: "SemiBold", size: 48, color: color(0xE8EAF6, 0.78), baseline: CGFloat(H) - 290, maxWidth: CGFloat(W) - 400, in: ctx)

    // The window below, as large as fits, with a soft shadow.
    let area = CGRect(x: 200, y: 70, width: CGFloat(W) - 400, height: CGFloat(H) - 420 - 70)
    let scale = min(area.width / CGFloat(source.width), area.height / CGFloat(source.height))
    let size = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
    let rect = CGRect(x: area.midX - size.width / 2, y: area.maxY - size.height, width: size.width, height: size.height)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 70, color: color(0x000000, 0.6))
    ctx.interpolationQuality = .high
    ctx.draw(source, in: rect)
    ctx.restoreGState()

    let out = folder.appending(path: shot.file)
    guard let image = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fail("Can't encode \(shot.file)")
    }
    try png.write(to: out)
    print("\(out.path) \(W)×\(H)")
}

guard let data = try? Data(contentsOf: raw.appending(path: "shots.json")),
      let shots = try? JSONDecoder().decode([Shot].self, from: data) else {
    fail("No \(raw.path)/shots.json: run the app with -SnazzyPro.screenshots YES first.")
}
for shot in shots { try frame(shot) }
