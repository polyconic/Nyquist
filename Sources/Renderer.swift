import AppKit
import CoreGraphics

/// How the many analysis cells behind one screen pixel are collapsed.
enum Pooling: String, CaseIterable {
    case average = "Avg"
    case typical = "Typ"
    case peak = "Peak"
}

struct RenderSettings {
    var pooling: Pooling = .average
    var colormapName: String = "SoX"
    var dbFloor: Double = -120
    var gain: Double = 0
    var logFrequency: Bool = false
    var colormap: Colormap { Colormap.named(colormapName) }
}

/// Visible window onto the spectrogram, in seconds and hertz.
struct ViewRange: Equatable {
    var t0: Double, t1: Double, f0: Double, f1: Double

    static func full(_ sg: Spectrogram) -> ViewRange {
        ViewRange(t0: 0, t1: max(sg.duration, 0.001), f0: 0, f1: sg.nyquist)
    }
    func clamped(to full: ViewRange, logFrequency: Bool) -> ViewRange {
        var r = self
        let minSpanT = max((full.t1 - full.t0) / 100_000, 0.0005)
        if r.t1 - r.t0 < minSpanT { r.t1 = r.t0 + minSpanT }
        if r.t0 < full.t0 { r.t1 += full.t0 - r.t0; r.t0 = full.t0 }
        if r.t1 > full.t1 { r.t0 -= r.t1 - full.t1; r.t1 = full.t1 }
        r.t0 = max(r.t0, full.t0); r.t1 = min(r.t1, full.t1)

        let lowest = logFrequency ? 10.0 : 0.0
        let minSpanF = max((full.f1 - lowest) / 2000, 1)
        if r.f1 - r.f0 < minSpanF { r.f1 = r.f0 + minSpanF }
        if r.f0 < lowest { r.f1 += lowest - r.f0; r.f0 = lowest }
        if r.f1 > full.f1 { r.f0 -= r.f1 - full.f1; r.f1 = full.f1 }
        r.f0 = max(r.f0, lowest); r.f1 = min(r.f1, full.f1)
        return r
    }
}

struct ChartLayout {
    var plot: CGRect
    var legend: CGRect
    var scale: CGFloat

    static func compute(size: CGSize, showHeader: Bool, showAxes: Bool) -> ChartLayout {
        let s = max(1.0, min(size.width / 1500, 6.0))
        guard showAxes else {
            return ChartLayout(plot: CGRect(origin: .zero, size: size), legend: .zero, scale: s)
        }
        let left = 62 * s, bottom = 34 * s
        let top = (showHeader ? 52 : 12) * s
        let legendBar = 20 * s, legendLabels = 52 * s, gap = 14 * s
        let right = legendBar + legendLabels + gap

        let plot = CGRect(x: left, y: bottom,
                          width: max(10, size.width - left - right),
                          height: max(10, size.height - bottom - top))
        let legend = CGRect(x: plot.maxX + gap, y: plot.minY, width: legendBar, height: plot.height)
        return ChartLayout(plot: plot, legend: legend, scale: s)
    }
}

enum SpectrogramRenderer {

    // MARK: - Heat map

    static func image(_ sg: Spectrogram, range: ViewRange, settings: RenderSettings,
                      pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        let w = max(1, pixelWidth), h = max(1, pixelHeight)
        let lut = settings.colormap.lut()
        let floor = settings.dbFloor
        let span = max(1.0, -floor)
        let gain = settings.gain

        // Per-column frame spans.
        var colStart = [Int](repeating: 0, count: w)
        var colEnd = [Int](repeating: 0, count: w)
        for x in 0..<w {
            let ta = range.t0 + (range.t1 - range.t0) * Double(x) / Double(w)
            let tb = range.t0 + (range.t1 - range.t0) * Double(x + 1) / Double(w)
            let a = sg.frame(atTime: ta)
            let b = max(a + 1, sg.frame(atTime: tb))
            colStart[x] = a
            colEnd[x] = min(b, sg.frameCount)
        }

        // Per-row bin spans; row 0 is the top of the image (highest frequency).
        var rowStart = [Int](repeating: 0, count: h)
        var rowEnd = [Int](repeating: 0, count: h)
        let logMode = settings.logFrequency
        let lf0 = log10(max(range.f0, 10.0)), lf1 = log10(max(range.f1, 20.0))
        for y in 0..<h {
            let fracTop = 1.0 - Double(y + 1) / Double(h)
            let fracBottom = 1.0 - Double(y) / Double(h)
            let hzA: Double, hzB: Double
            if logMode {
                hzA = pow(10, lf0 + (lf1 - lf0) * fracTop)
                hzB = pow(10, lf0 + (lf1 - lf0) * fracBottom)
            } else {
                hzA = range.f0 + (range.f1 - range.f0) * fracTop
                hzB = range.f0 + (range.f1 - range.f0) * fracBottom
            }
            let a = sg.bin(atFrequency: hzA)
            let b = max(a + 1, sg.bin(atFrequency: hzB) + 1)
            rowStart[y] = a
            rowEnd[y] = min(b, sg.binCount)
        }

        var pixels = [UInt32](repeating: 0, count: w * h)
        let binCount = sg.binCount
        let pooling = settings.pooling

        pixels.withUnsafeMutableBufferPointer { out in
            let outBase = out.baseAddress!
            sg.db.withUnsafeBufferPointer { dbBuf in
                let db = dbBuf.baseAddress!
                let chunk = max(1, w / max(1, ProcessInfo.processInfo.activeProcessorCount))
                let chunks = (w + chunk - 1) / chunk
                DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                    let xStart = ci * chunk, xEnd = min(xStart + chunk, w)
                    guard xStart < xEnd else { return }
                    for x in xStart..<xEnd {
                        let f0 = colStart[x], f1 = colEnd[x]
                        for y in 0..<h {
                            let b0 = rowStart[y], b1 = rowEnd[y]
                            var value: Float = -300
                            if pooling == .average {
                                // Mean power, so collapsing N cells does not inflate the
                                // noise floor the way a peak does. dB -> power is
                                // 10^(v/10) == exp2(v * log2(10)/10).
                                var sum: Float = 0
                                var n = 0
                                var f = f0
                                while f < f1 {
                                    let row = db + f * binCount
                                    var b = b0
                                    while b < b1 {
                                        sum += exp2f(row[b] * 0.332192809)
                                        b += 1; n += 1
                                    }
                                    f += 1
                                }
                                if n > 0 && sum > 0 { value = log2f(sum / Float(n)) * 3.01029996 }
                            } else if pooling == .typical {
                                // Mean of the dB values, as Spek does. Bursty content such
                                // as hi-hats sinks toward the level between hits.
                                var sum: Float = 0
                                var n = 0
                                var f = f0
                                while f < f1 {
                                    let row = db + f * binCount
                                    var b = b0
                                    while b < b1 { sum += row[b]; b += 1; n += 1 }
                                    f += 1
                                }
                                if n > 0 { value = sum / Float(n) }
                            } else {
                                var f = f0
                                while f < f1 {
                                    let row = db + f * binCount
                                    var b = b0
                                    while b < b1 {
                                        let v = row[b]
                                        if v > value { value = v }
                                        b += 1
                                    }
                                    f += 1
                                }
                            }
                            let norm = (Double(value) + gain - floor) / span
                            let idx = norm <= 0 ? 0 : (norm >= 1 ? 255 : Int(norm * 255))
                            outBase[y * w + x] = lut[idx]
                        }
                    }
                }
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        return pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: cs, bitmapInfo: info.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }

    // MARK: - Full chart

    struct ChartInput {
        var spectrogram: Spectrogram?
        var range: ViewRange
        var settings: RenderSettings
        var headerPath: String
        var headerStream: String
        var showHeader: Bool = true
        var showAxes: Bool = true
        var heatImage: CGImage? = nil   // reuse a cached image instead of re-rendering
    }

    static func drawChart(in ctx: CGContext, size: CGSize, input: ChartInput, pixelScale: CGFloat) {
        let layout = ChartLayout.compute(size: size, showHeader: input.showHeader, showAxes: input.showAxes)
        let s = layout.scale

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        guard let sg = input.spectrogram else { return }

        let heat = input.heatImage ?? image(sg, range: input.range, settings: input.settings,
                                            pixelWidth: Int(layout.plot.width * pixelScale),
                                            pixelHeight: Int(layout.plot.height * pixelScale))
        if let heat {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.draw(heat, in: layout.plot)
            ctx.restoreGState()
        }

        guard input.showAxes else { return }

        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor)
        ctx.setLineWidth(1 * s)
        ctx.stroke(layout.plot.insetBy(dx: -0.5 * s, dy: -0.5 * s))

        drawFrequencyAxis(ctx, layout: layout, range: input.range, log: input.settings.logFrequency)
        drawTimeAxis(ctx, layout: layout, range: input.range)
        drawLegend(ctx, layout: layout, settings: input.settings)

        if input.showHeader {
            let pathFont = NSFont.boldSystemFont(ofSize: 13 * s)
            let infoFont = NSFont.systemFont(ofSize: 11 * s)
            draw(input.headerPath, at: CGPoint(x: layout.plot.minX, y: size.height - 22 * s),
                 font: pathFont, color: .white, ctx: ctx)
            draw(input.headerStream, at: CGPoint(x: layout.plot.minX, y: size.height - 38 * s),
                 font: infoFont, color: NSColor(white: 0.78, alpha: 1), ctx: ctx)

            let brand = NSMutableAttributedString(
                string: AppInfo.name,
                attributes: [.font: NSFont.boldSystemFont(ofSize: 13 * s), .foregroundColor: NSColor.white])
            brand.append(NSAttributedString(
                string: "  " + AppInfo.version,
                attributes: [.font: NSFont.systemFont(ofSize: 11 * s),
                             .foregroundColor: NSColor(white: 0.6, alpha: 1)]))
            let bw = brand.size().width
            drawAttributed(brand, at: CGPoint(x: size.width - bw - 10 * s, y: size.height - 22 * s), ctx: ctx)
        }
    }

    // MARK: - Axes

    static func yPosition(hz: Double, range: ViewRange, plot: CGRect, log: Bool) -> CGFloat {
        if log {
            let l0 = log10(max(range.f0, 10.0)), l1 = log10(max(range.f1, 20.0))
            guard l1 > l0 else { return plot.minY }
            return plot.minY + plot.height * CGFloat((log10(max(hz, 10.0)) - l0) / (l1 - l0))
        }
        guard range.f1 > range.f0 else { return plot.minY }
        return plot.minY + plot.height * CGFloat((hz - range.f0) / (range.f1 - range.f0))
    }

    static func frequency(atY y: CGFloat, range: ViewRange, plot: CGRect, log: Bool) -> Double {
        let frac = Double((y - plot.minY) / max(plot.height, 1))
        if log {
            let l0 = log10(max(range.f0, 10.0)), l1 = log10(max(range.f1, 20.0))
            return pow(10, l0 + (l1 - l0) * frac)
        }
        return range.f0 + (range.f1 - range.f0) * frac
    }

    static func xPosition(time: Double, range: ViewRange, plot: CGRect) -> CGFloat {
        guard range.t1 > range.t0 else { return plot.minX }
        return plot.minX + plot.width * CGFloat((time - range.t0) / (range.t1 - range.t0))
    }

    static func time(atX x: CGFloat, range: ViewRange, plot: CGRect) -> Double {
        range.t0 + (range.t1 - range.t0) * Double((x - plot.minX) / max(plot.width, 1))
    }

    private static func drawFrequencyAxis(_ ctx: CGContext, layout: ChartLayout,
                                          range: ViewRange, log: Bool) {
        let plot = layout.plot, s = layout.scale
        let font = NSFont.systemFont(ofSize: 10 * s)
        let ticks = log ? logFrequencyTicks(range) : linearFrequencyTicks(range, height: plot.height, scale: s)

        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor)
        ctx.setLineWidth(1 * s)
        for hz in ticks {
            let y = yPosition(hz: hz, range: range, plot: plot, log: log)
            guard y >= plot.minY - 1, y <= plot.maxY + 1 else { continue }
            ctx.move(to: CGPoint(x: plot.minX - 5 * s, y: y))
            ctx.addLine(to: CGPoint(x: plot.minX, y: y))
            ctx.strokePath()
            let label = formatHz(hz)
            let w = (label as NSString).size(withAttributes: [.font: font]).width
            draw(label, at: CGPoint(x: plot.minX - 9 * s - w, y: y - 6 * s),
                 font: font, color: NSColor(white: 0.92, alpha: 1), ctx: ctx)
        }
    }

    private static func linearFrequencyTicks(_ range: ViewRange, height: CGFloat, scale: CGFloat) -> [Double] {
        let span = range.f1 - range.f0
        let target = Double(height / (26 * scale))
        let rough = span / max(target, 1)
        let step = niceStep(rough)
        var ticks: [Double] = []
        var v = (range.f0 / step).rounded(.down) * step
        while v <= range.f1 + step * 0.001 {
            if v >= range.f0 - 0.001 { ticks.append(v) }
            v += step
        }
        return ticks
    }

    private static func logFrequencyTicks(_ range: ViewRange) -> [Double] {
        var ticks: [Double] = []
        var decade = pow(10, (log10(max(range.f0, 10))).rounded(.down))
        while decade <= range.f1 {
            for m in [1.0, 2.0, 5.0] {
                let v = decade * m
                if v >= range.f0 && v <= range.f1 { ticks.append(v) }
            }
            decade *= 10
        }
        return ticks
    }

    private static func niceStep(_ rough: Double) -> Double {
        guard rough > 0 else { return 1 }
        let mag = pow(10, log10(rough).rounded(.down))
        let n = rough / mag
        let mult: Double = n <= 1 ? 1 : (n <= 2 ? 2 : (n <= 5 ? 5 : 10))
        return mult * mag
    }

    private static func formatHz(_ hz: Double) -> String {
        if hz >= 1000 {
            let k = hz / 1000
            return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
        }
        return hz == hz.rounded() ? "\(Int(hz)) Hz" : String(format: "%.0f Hz", hz)
    }

    private static func drawTimeAxis(_ ctx: CGContext, layout: ChartLayout, range: ViewRange) {
        let plot = layout.plot, s = layout.scale
        let font = NSFont.systemFont(ofSize: 10 * s)
        let span = range.t1 - range.t0
        let target = Double(plot.width / (72 * s))
        let step = niceTimeStep(span / max(target, 1))

        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor)
        ctx.setLineWidth(1 * s)
        var t = (range.t0 / step).rounded(.down) * step
        while t <= range.t1 + step * 0.001 {
            defer { t += step }
            guard t >= range.t0 - 0.001 else { continue }
            let x = xPosition(time: t, range: range, plot: plot)
            guard x >= plot.minX - 1, x <= plot.maxX + 1 else { continue }
            ctx.move(to: CGPoint(x: x, y: plot.minY - 5 * s))
            ctx.addLine(to: CGPoint(x: x, y: plot.minY))
            ctx.strokePath()
            let label = formatTime(t, step: step)
            let w = (label as NSString).size(withAttributes: [.font: font]).width
            draw(label, at: CGPoint(x: x - w / 2, y: plot.minY - 20 * s),
                 font: font, color: NSColor(white: 0.92, alpha: 1), ctx: ctx)
        }
    }

    private static func niceTimeStep(_ rough: Double) -> Double {
        let candidates: [Double] = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5,
                                    1, 2, 5, 10, 15, 20, 30, 60, 120, 300, 600, 900, 1800, 3600]
        return candidates.first { $0 >= rough } ?? 3600
    }

    static func formatTime(_ t: Double, step: Double) -> String {
        let m = Int(t) / 60
        let sec = t - Double(m * 60)
        if step < 1 { return String(format: "%d:%06.3f", m, sec) }
        return String(format: "%d:%02d", m, Int(sec.rounded()))
    }

    private static func drawLegend(_ ctx: CGContext, layout: ChartLayout, settings: RenderSettings) {
        let bar = layout.legend, s = layout.scale
        guard bar.width > 0 else { return }
        let lut = settings.colormap.lut()
        let steps = max(2, Int(bar.height))
        for i in 0..<steps {
            let frac = Double(i) / Double(steps - 1)
            let v = lut[Int(frac * 255)]
            ctx.setFillColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                             green: CGFloat((v >> 8) & 0xFF) / 255,
                             blue: CGFloat(v & 0xFF) / 255, alpha: 1)
            let y = bar.minY + bar.height * CGFloat(i) / CGFloat(steps)
            ctx.fill(CGRect(x: bar.minX, y: y, width: bar.width,
                            height: bar.height / CGFloat(steps) + 1))
        }
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor)
        ctx.setLineWidth(1 * s)
        ctx.stroke(bar)

        let font = NSFont.systemFont(ofSize: 10 * s)
        let floor = settings.dbFloor
        let step = niceStep(-floor / Double(bar.height / (24 * s)))
        var db = 0.0
        while db >= floor - 0.001 {
            let frac = (db - floor) / (0 - floor)
            let y = bar.minY + bar.height * CGFloat(frac)
            ctx.move(to: CGPoint(x: bar.maxX, y: y))
            ctx.addLine(to: CGPoint(x: bar.maxX + 4 * s, y: y))
            ctx.strokePath()
            draw(String(format: "%.0f dB", db), at: CGPoint(x: bar.maxX + 7 * s, y: y - 6 * s),
                 font: font, color: NSColor(white: 0.92, alpha: 1), ctx: ctx)
            db -= step
        }
    }

    // MARK: - Text

    private static func draw(_ text: String, at p: CGPoint, font: NSFont, color: NSColor, ctx: CGContext) {
        drawAttributed(NSAttributedString(string: text,
                                          attributes: [.font: font, .foregroundColor: color]),
                       at: p, ctx: ctx)
    }

    private static func drawAttributed(_ s: NSAttributedString, at p: CGPoint, ctx: CGContext) {
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        s.draw(at: p)
        NSGraphicsContext.current = saved
    }
}
