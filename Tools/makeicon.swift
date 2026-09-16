import AppKit
import Foundation

// Renders the app icon: a dark squircle holding a stylised spectrogram.
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

let stops: [(Double, Double, Double, Double)] = [
    (0.00, 0, 0, 0), (0.08, 12, 8, 40), (0.16, 28, 12, 74), (0.24, 48, 14, 106),
    (0.32, 74, 16, 124), (0.40, 104, 20, 130), (0.48, 136, 26, 128),
    (0.56, 168, 34, 118), (0.64, 198, 44, 100), (0.70, 219, 58, 79),
    (0.76, 234, 78, 58), (0.82, 244, 103, 40), (0.88, 250, 134, 28),
    (0.93, 253, 170, 30), (0.97, 254, 209, 64), (1.00, 255, 255, 220)]

func color(_ t: Double) -> NSColor {
    let v = min(max(t, 0), 1)
    var seg = 0
    while seg < stops.count - 2 && v > stops[seg + 1].0 { seg += 1 }
    let a = stops[seg], b = stops[seg + 1]
    let f = (v - a.0) / max(b.0 - a.0, 1e-9)
    return NSColor(srgbRed: CGFloat(a.1 + (b.1 - a.1) * f) / 255,
                   green: CGFloat(a.2 + (b.2 - a.2) * f) / 255,
                   blue: CGFloat(a.3 + (b.3 - a.3) * f) / 255, alpha: 1)
}

/// A synthetic spectrogram: steep spectral tilt, rhythmic columns, a few low
/// harmonics. Deterministic, so every rendered size shows the same image.
func energy(_ x: Double, _ y: Double) -> Double {
    // y: 0 at the bottom (low frequency), 1 at the top.
    var e = 0.95 * exp(-y * 2.6)

    // Rhythmic transients: dense, uneven in strength, fading fast with frequency.
    let pulse = pow(max(0, sin(x * Double.pi * 14.0)), 16.0)
    let vary = 0.55 + 0.45 * sin(x * 7.3 + 1.1)
    e += 0.42 * pulse * vary * exp(-y * 1.6)

    // Sustained harmonics across the bottom third.
    for (h, a, w) in [(0.04, 0.60, 0.016), (0.10, 0.36, 0.014),
                      (0.175, 0.22, 0.013), (0.27, 0.12, 0.012)] {
        let d = (y - h) / w
        e += a * exp(-d * d)
    }

    // Slow swell so the image is not uniform left to right.
    e *= 0.84 + 0.16 * sin(x * 2.1 + 0.6)

    // Irregular grain — a regular sin/cos product moirés at icon sizes.
    let n = sin(x * 311.7 + y * 173.3) * 43758.5453
    e += 0.028 * (n - n.rounded(.down) - 0.5)

    return min(max(e, 0), 1)
}

func render(_ size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = CGFloat(size)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS squircle proportions, with a small inset so it sits like other icons.
    let inset = s * 0.055
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.height * 0.2237)
    ctx.saveGState()
    path.addClip()

    NSColor(srgbRed: 0.055, green: 0.05, blue: 0.075, alpha: 1).setFill()
    rect.fill()

    // Plot area inside the tile.
    let pad = rect.width * 0.115
    let plot = rect.insetBy(dx: pad, dy: pad)
    let cols = max(48, size / 3)
    let rows = max(48, size / 3)
    let cw = plot.width / CGFloat(cols)
    let rh = plot.height / CGFloat(rows)
    for i in 0..<cols {
        let x = Double(i) / Double(cols - 1)
        for j in 0..<rows {
            let y = Double(j) / Double(rows - 1)   // 0 = bottom = low frequency
            color(energy(x, y)).setFill()
            NSRect(x: plot.minX + CGFloat(i) * cw, y: plot.minY + CGFloat(j) * rh,
                   width: cw + 0.7, height: rh + 0.7).fill()
        }
    }

    // Top gloss and inner edge.
    let gloss = NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0.0)])
    gloss?.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2),
                angle: -90)
    ctx.restoreGState()

    NSColor(white: 1, alpha: 0.16).setStroke()
    path.lineWidth = max(1, s * 0.006)
    path.stroke()

    image.unlockFocus()
    return image
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let img = render(size)
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(size).png"))
}
print("icons written to \(outDir)")
