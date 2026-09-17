import AppKit

struct Colormap {
    let name: String
    /// Control points as (position 0...1, r, g, b) with 0-255 components.
    let stops: [(Double, Double, Double, Double)]

    /// 256-entry lookup table, premultiplied into BGRA byte order for CGImage.
    func lut() -> [UInt32] {
        var table = [UInt32](repeating: 0, count: 256)
        var seg = 0
        for i in 0..<256 {
            let t = Double(i) / 255.0
            while seg < stops.count - 2 && t > stops[seg + 1].0 { seg += 1 }
            let a = stops[seg], b = stops[seg + 1]
            let span = b.0 - a.0
            let f = span <= 0 ? 0 : min(max((t - a.0) / span, 0), 1)
            let r = UInt32(round(a.1 + (b.1 - a.1) * f))
            let g = UInt32(round(a.2 + (b.2 - a.2) * f))
            let bl = UInt32(round(a.3 + (b.3 - a.3) * f))
            // kCGImageAlphaNoneSkipFirst | littleEndian32 => 0xAARRGGBB in a UInt32
            table[i] = (0xFF << 24) | (r << 16) | (g << 8) | bl
        }
        return table
    }

    func color(at t: Double) -> NSColor {
        let v = lut()[Int(min(max(t, 0), 1) * 255)]
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static let all: [Colormap] = [sox, magma, inferno, plasma, viridis, turbo,
                                  cividis, fire, ice, spectrum, grayscale]

    static func named(_ n: String) -> Colormap { all.first { $0.name == n } ?? sox }

    /// Rob Sykes's SoX palette, which Spek also uses. Sampled from the formula
    /// rather than approximated, so it matches exactly.
    static let sox: Colormap = {
        func channel(_ l: Double) -> (Double, Double, Double) {
            var r = 0.0, g = 0.0, b = 0.0
            if l >= 0.13 && l < 0.73 { r = sin((l - 0.13) / 0.60 * .pi / 2) } else if l >= 0.73 { r = 1 }
            if l >= 0.6 && l < 0.91 { g = sin((l - 0.6) / 0.31 * .pi / 2) } else if l >= 0.91 { g = 1 }
            if l < 0.60 { b = 0.5 * sin(l / 0.6 * .pi) } else if l >= 0.78 { b = (l - 0.78) / 0.22 }
            return (r * 255, g * 255, b * 255)
        }
        let stops = (0...128).map { i -> (Double, Double, Double, Double) in
            let t = Double(i) / 128
            let c = channel(t)
            return (t, c.0, c.1, c.2)
        }
        return Colormap(name: "SoX", stops: stops)
    }()

    static let magma = Colormap(name: "Magma", stops: [
        (0.00, 0, 0, 4), (0.05, 8, 7, 29), (0.10, 20, 14, 54), (0.15, 36, 18, 80),
        (0.20, 55, 20, 105), (0.25, 75, 22, 122), (0.30, 94, 28, 129),
        (0.35, 113, 35, 133), (0.40, 131, 42, 134), (0.45, 150, 49, 133),
        (0.50, 169, 56, 130), (0.55, 188, 64, 124), (0.60, 206, 73, 117),
        (0.65, 222, 85, 108), (0.70, 235, 101, 101), (0.75, 245, 122, 101),
        (0.80, 250, 145, 110), (0.85, 253, 169, 126), (0.90, 254, 193, 147),
        (0.95, 254, 217, 173), (1.00, 252, 253, 191)])

    static let inferno = Colormap(name: "Inferno", stops: [
        (0.00, 0, 0, 4), (0.05, 9, 6, 30), (0.10, 22, 11, 57), (0.15, 38, 13, 84),
        (0.20, 57, 15, 110), (0.25, 74, 12, 127), (0.30, 90, 17, 134),
        (0.35, 106, 23, 137), (0.40, 122, 28, 138), (0.45, 137, 34, 136),
        (0.50, 153, 41, 133), (0.55, 169, 48, 126), (0.60, 185, 56, 118),
        (0.65, 200, 66, 107), (0.70, 215, 78, 95), (0.75, 228, 92, 81),
        (0.80, 238, 110, 65), (0.85, 246, 131, 48), (0.90, 250, 154, 31),
        (0.95, 247, 209, 61), (1.00, 252, 255, 164)])

    static let plasma = Colormap(name: "Plasma", stops: [
        (0.00, 13, 8, 135), (0.05, 42, 6, 140), (0.10, 65, 4, 141), (0.15, 86, 1, 140),
        (0.20, 106, 0, 136), (0.25, 125, 3, 129), (0.30, 143, 13, 120),
        (0.35, 159, 26, 110), (0.40, 175, 39, 101), (0.45, 189, 54, 92),
        (0.50, 203, 69, 83), (0.55, 215, 85, 74), (0.60, 226, 102, 65),
        (0.65, 236, 120, 55), (0.70, 244, 139, 46), (0.75, 250, 159, 37),
        (0.80, 253, 180, 30), (0.85, 253, 202, 30), (0.90, 248, 223, 45),
        (1.00, 240, 249, 33)])

    static let viridis = Colormap(name: "Viridis", stops: [
        (0.00, 68, 1, 84), (0.05, 71, 17, 100), (0.10, 72, 32, 113), (0.15, 70, 47, 124),
        (0.20, 66, 62, 133), (0.25, 60, 75, 138), (0.30, 54, 87, 141),
        (0.35, 48, 99, 142), (0.40, 42, 111, 142), (0.45, 38, 122, 142),
        (0.50, 33, 134, 141), (0.55, 30, 146, 139), (0.60, 31, 157, 136),
        (0.65, 40, 169, 130), (0.70, 59, 180, 122), (0.75, 86, 191, 110),
        (0.80, 116, 201, 98), (0.85, 151, 210, 79), (0.90, 188, 217, 60),
        (0.95, 222, 223, 39), (1.00, 253, 231, 37)])

    static let turbo = Colormap(name: "Turbo", stops: [
        (0.00, 48, 18, 59), (0.05, 57, 46, 126), (0.10, 64, 75, 177), (0.15, 68, 104, 213),
        (0.20, 70, 131, 236), (0.25, 65, 157, 247), (0.30, 52, 181, 242),
        (0.35, 38, 202, 224), (0.40, 28, 219, 199), (0.45, 28, 231, 171),
        (0.50, 50, 238, 138), (0.55, 86, 243, 105), (0.60, 126, 246, 77),
        (0.65, 163, 242, 56), (0.70, 194, 232, 44), (0.75, 219, 217, 39),
        (0.80, 238, 196, 38), (0.85, 250, 170, 37), (0.90, 252, 139, 32),
        (0.95, 231, 72, 16), (0.98, 185, 33, 7), (1.00, 122, 4, 3)])

    static let cividis = Colormap(name: "Cividis", stops: [
        (0.00, 0, 32, 76), (0.10, 0, 49, 111), (0.20, 26, 66, 120), (0.30, 63, 82, 116),
        (0.40, 91, 99, 117), (0.50, 117, 115, 122), (0.60, 145, 133, 120),
        (0.70, 176, 152, 111), (0.80, 208, 172, 96), (0.90, 242, 194, 73),
        (1.00, 255, 233, 69)])

    static let fire = Colormap(name: "Fire", stops: [
        (0.00, 0, 0, 0), (0.15, 40, 0, 0), (0.35, 120, 6, 0), (0.55, 200, 30, 0),
        (0.72, 240, 90, 0), (0.86, 252, 160, 10), (0.95, 255, 214, 80),
        (1.00, 255, 255, 235)])

    static let ice = Colormap(name: "Ice", stops: [
        (0.00, 0, 0, 0), (0.15, 4, 14, 48), (0.35, 6, 40, 110), (0.55, 10, 88, 176),
        (0.72, 32, 146, 216), (0.86, 96, 198, 236), (0.95, 176, 230, 248),
        (1.00, 245, 253, 255)])

    static let spectrum = Colormap(name: "Spectrum", stops: [
        (0.00, 0, 0, 0), (0.12, 12, 4, 72), (0.28, 10, 40, 170), (0.42, 0, 130, 200),
        (0.55, 0, 180, 130), (0.66, 90, 210, 40), (0.76, 200, 220, 0),
        (0.85, 250, 170, 0), (0.93, 246, 80, 20), (1.00, 255, 255, 255)])

    static let grayscale = Colormap(name: "Grayscale", stops: [
        (0.00, 0, 0, 0), (1.00, 255, 255, 255)])
}
