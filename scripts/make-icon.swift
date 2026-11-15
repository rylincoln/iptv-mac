// Draws Tuner's app icon and writes it as a 1024 × 1024 PNG.  Usage: swift scripts/make-icon.swift out.png
// The design is described in docs/design/held-signal.md: a play triangle built from scan lines, one of
// them the held signal.
import AppKit

let side = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
        ])!
}

/// The macOS icon shape: a superellipse on the 824-point grid, centred.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(in: plate)

// The plate's shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0x000000, 0.38))
ctx.addPath(shape)
ctx.setFillColor(rgb(0x0C0D10))
ctx.fillPath()
ctx.restoreGState()

// The field: graphite, falling slowly darker, with a little lift behind the form.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let fall = CGGradient(colorsSpace: space, colors: [rgb(0x23262D), rgb(0x0A0B0E)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(fall, start: CGPoint(x: 512, y: plate.maxY), end: CGPoint(x: 512, y: plate.minY), options: [])
let lift = CGGradient(
    colorsSpace: space, colors: [rgb(0x3A4150, 0.38), rgb(0x3A4150, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(
    lift, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560),
    endRadius: 430, options: [])
ctx.restoreGState()

// A hairline of light where the edge turns, strongest at the top.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.addPath(shape)
ctx.setLineWidth(5)
ctx.replacePathWithStrokedPath()
ctx.clip()
let edge = CGGradient(
    colorsSpace: space, colors: [rgb(0xFFFFFF, 0.20), rgb(0xFFFFFF, 0.02)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(edge, start: CGPoint(x: 512, y: plate.maxY), end: CGPoint(x: 512, y: 512), options: [])
ctx.restoreGState()

// The form: a play triangle made of scan lines at one pitch and one weight. The middle line, the
// longest, is the held signal.
let lines = 11
let pitch: CGFloat = 44
let weight: CGFloat = 26
let left: CGFloat = 318
let reach: CGFloat = 420  // the middle line's length
let middle = lines / 2
let bone = rgb(0xEDEAE3)
let signal = rgb(0xFF4B2B)

func bar(_ index: Int) -> CGPath {
    let away = CGFloat(abs(index - middle)) / (CGFloat(lines) / 2)
    let length = max(weight, reach * (1 - away))
    let y = 512 + CGFloat(middle - index) * pitch
    let rect = CGRect(x: left, y: y - weight / 2, width: length, height: weight)
    return CGPath(roundedRect: rect, cornerWidth: weight / 2, cornerHeight: weight / 2, transform: nil)
}

for index in 0..<lines where index != middle {
    // Each line a touch quieter the further it is from the signal.
    let away = CGFloat(abs(index - middle)) / CGFloat(middle)
    ctx.addPath(bar(index))
    ctx.setFillColor(bone.copy(alpha: 0.96 - 0.34 * away)!)
    ctx.fillPath()
}

// The signal, live: a wide soft glow, a tight one, then the line itself.
for (blur, alpha) in [(CGFloat(70), CGFloat(0.55)), (CGFloat(18), CGFloat(0.8))] {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: signal.copy(alpha: alpha))
    ctx.addPath(bar(middle))
    ctx.setFillColor(signal)
    ctx.fillPath()
    ctx.restoreGState()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
