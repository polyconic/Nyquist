import AppKit

// Shared by Nyquist and Manifest; keep the two copies identical.

struct StereoPanelModel {
    var title: String
    var duration: Double
    var stereo: StereoAnalysis.Result
    var channelCount: Int
    var note: String? = nil
}

/// Floating window showing one track's stereo picture.
final class StereoPanelController: NSWindowController, NSWindowDelegate {

    private let panelView = StereoPanelView()
    var onClose: () -> Void = {}

    var model: StereoPanelModel? {
        didSet {
            panelView.model = model
            if model != nil { panelView.message = nil }
            window?.title = model.map { "Stereo — \($0.title)" } ?? "Stereo"
        }
    }

    /// Shown in place of the graphs, e.g. while the analysis runs.
    var message: String? {
        get { panelView.message }
        set { panelView.message = newValue }
    }

    var colormap: Colormap {
        get { panelView.colormap }
        set { panelView.colormap = newValue }
    }

    var isShown: Bool { window?.isVisible ?? false }

    convenience init(autosaveName: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 780),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Stereo"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 340, height: 620)
        self.init(window: panel)
        panel.contentView = panelView
        panel.delegate = self
        self.autosaveName = autosaveName
    }

    private var autosaveName = "StereoPanel"

    /// Opens beside `anchor` the first time; after that macOS restores where it was left.
    func show(beside anchor: NSWindow?) {
        guard let panel = window else { return }
        if !panel.setFrameUsingName(autosaveName), let anchor, let screen = anchor.screen {
            let f = anchor.frame
            var x = f.maxX + 8
            if x + panel.frame.width > screen.visibleFrame.maxX {
                x = f.maxX - panel.frame.width - 16
            }
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: f.maxY))
        }
        panel.setFrameAutosaveName(autosaveName)
        showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

final class StereoPanelView: NSView {

    var model: StereoPanelModel? { didSet { scopeImage = nil; needsDisplay = true } }
    var message: String? { didSet { needsDisplay = true } }
    var colormap: Colormap = .sox { didSet { scopeImage = nil; needsDisplay = true } }
    private var scopeImage: CGImage?

    override var isFlipped: Bool { false }

    private let pad: CGFloat = 16
    private let background = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.07, alpha: 1)
    private let text = NSColor(white: 0.94, alpha: 1)
    private let dim = NSColor(white: 0.58, alpha: 1)
    private let warn = NSColor(srgbRed: 0.98, green: 0.74, blue: 0.24, alpha: 1)
    private let fail = NSColor(srgbRed: 0.98, green: 0.35, blue: 0.35, alpha: 1)
    private let bassColor = NSColor(srgbRed: 0.98, green: 0.62, blue: 0.25, alpha: 1)
    private let wideColor = NSColor(srgbRed: 0.35, green: 0.72, blue: 0.95, alpha: 1)

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(background.cgColor)
        ctx.fill(bounds)

        guard let m = model, message == nil else {
            centered(message ?? "Nothing loaded", in: bounds, font: .systemFont(ofSize: 13), color: dim)
            return
        }
        let s = m.stereo
        let w = bounds.width - pad * 2
        var y = bounds.height - pad

        y -= wrapped(m.title, x: pad, top: y, width: w,
                     font: .systemFont(ofSize: 14, weight: .semibold), color: text, maxLines: 2)
        if let note = m.note {
            y -= 4
            y -= wrapped(note, x: pad, top: y, width: w, font: .systemFont(ofSize: 10), color: warn, maxLines: 2)
        }
        y -= 12

        guard m.channelCount >= 2 else {
            centered("Mono file — there is no stereo picture to show.",
                     in: CGRect(x: 0, y: 0, width: bounds.width, height: y),
                     font: .systemFont(ofSize: 12), color: dim)
            return
        }

        let side = max(160, min(w, y - 342))
        let scope = CGRect(x: pad + (w - side) / 2, y: y - side, width: side, height: side)
        drawScope(s, in: scope, ctx: ctx)
        y = scope.minY - 22

        y -= label("CORRELATION", y: y)
        let meter = CGRect(x: pad, y: y - 34, width: w, height: 34)
        drawMeter(s, in: meter, ctx: ctx)
        y = meter.minY - 30

        y -= label("OVER TIME", y: y)
        let strip = CGRect(x: pad, y: y - 70, width: w, height: 70)
        drawTimeline(s, duration: m.duration, in: strip, ctx: ctx)
        y = strip.minY - 18

        let figures: [(String, String, NSColor)] = [
            ("CORRELATION", String(format: "%+.2f", s.overall), text),
            ("BASS CORR", String(format: "%+.3f", s.lowOverall), s.lowFractionNegative > 0.01 ? fail : text),
            ("WORST BLOCK", String(format: "%+.2f", s.minimum), s.minimum < 0 ? warn : text),
            ("WIDTH", s.sideToMidDB > -60 ? String(format: "%.1f dB", s.sideToMidDB) : "mono", text),
            ("BALANCE", balanceText(s.balanceDB), abs(s.balanceDB) > 1 ? warn : text),
            ("BASS OUT OF PHASE", String(format: "%.2f%%", s.lowFractionNegative * 100),
             s.lowFractionNegative > 0.01 ? fail : text),
        ]
        let colW = w / 3
        for (i, f) in figures.enumerated() {
            let fx = pad + CGFloat(i % 3) * colW
            let fy = y - CGFloat(i / 3) * 44
            draw(f.0, at: CGPoint(x: fx, y: fy - 10), font: .systemFont(ofSize: 8.5, weight: .semibold), color: dim)
            draw(f.1, at: CGPoint(x: fx, y: fy - 30),
                 font: .monospacedDigitSystemFont(ofSize: 15, weight: .medium), color: f.2)
        }
        y -= 92

        let guide = "Vertical line: mono. Wider cloud: more stereo. A smear toward the "
            + "horizontal axis is out-of-phase content that cancels when summed to mono. "
            + "A lean toward L or R is imbalance."
        _ = wrapped(guide, x: pad, top: y, width: w, font: .systemFont(ofSize: 10), color: dim, maxLines: 4)
    }

    private func label(_ s: String, y: CGFloat) -> CGFloat {
        draw(s, at: CGPoint(x: pad, y: y - 10), font: .systemFont(ofSize: 8.5, weight: .semibold), color: dim)
        return 16
    }

    private func balanceText(_ db: Double) -> String {
        abs(db) < 0.05 ? "centered" : String(format: "%.1f dB %@", abs(db), db > 0 ? "L" : "R")
    }

    // MARK: - Graphs

    private func buildScope(_ s: StereoAnalysis.Result) -> CGImage? {
        let size = s.vectorscopeSize
        guard size > 0, s.vectorscope.count == size * size else { return nil }
        let lut = colormap.lut()
        var pixels = s.vectorscope.map { lut[Int(min(max(Double($0), 0), 1) * 255)] }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        return pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: info.rawValue)?.makeImage()
        }
    }

    private func drawScope(_ s: StereoAnalysis.Result, in box: CGRect, ctx: CGContext) {
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(box)
        if scopeImage == nil { scopeImage = buildScope(s) }
        if let img = scopeImage {
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.draw(img, in: box)
            ctx.restoreGState()
        }

        // Mono vertical; out-of-phase horizontal; hard left and right on the diagonals.
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.28).cgColor)
        ctx.move(to: CGPoint(x: box.midX, y: box.minY)); ctx.addLine(to: CGPoint(x: box.midX, y: box.maxY))
        ctx.strokePath()
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.14).cgColor)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        ctx.move(to: CGPoint(x: box.minX, y: box.midY)); ctx.addLine(to: CGPoint(x: box.maxX, y: box.midY))
        ctx.move(to: CGPoint(x: box.minX, y: box.minY)); ctx.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        ctx.move(to: CGPoint(x: box.maxX, y: box.minY)); ctx.addLine(to: CGPoint(x: box.minX, y: box.maxY))
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.2).cgColor)
        ctx.stroke(box)

        let f = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let c = NSColor(white: 1, alpha: 0.7)
        centered("M", in: CGRect(x: box.midX - 12, y: box.maxY - 22, width: 24, height: 18), font: f, color: c)
        draw("L", at: CGPoint(x: box.minX + 8, y: box.maxY - 22), font: f, color: c)
        draw("R", at: CGPoint(x: box.maxX - 16, y: box.maxY - 22), font: f, color: c)
        draw("OUT OF PHASE", at: CGPoint(x: box.minX + 6, y: box.midY + 4),
             font: .systemFont(ofSize: 8.5, weight: .semibold), color: NSColor(white: 1, alpha: 0.4))
    }

    private func drawMeter(_ s: StereoAnalysis.Result, in box: CGRect, ctx: CGContext) {
        let bar = CGRect(x: box.minX, y: box.midY - 5, width: box.width, height: 10)
        let colors = [fail.cgColor, NSColor(white: 0.35, alpha: 1).cgColor, wideColor.cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
            ctx.saveGState()
            ctx.clip(to: bar)
            ctx.drawLinearGradient(g, start: CGPoint(x: bar.minX, y: 0), end: CGPoint(x: bar.maxX, y: 0), options: [])
            ctx.restoreGState()
        }
        let tickFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
        for v in [-1.0, -0.5, 0, 0.5, 1] {
            let x = bar.minX + bar.width * CGFloat((v + 1) / 2)
            let t = v == 0 ? "0" : String(format: "%+.1f", v)
            let tw = (t as NSString).size(withAttributes: [.font: tickFont]).width
            draw(t, at: CGPoint(x: min(max(x - tw / 2, bar.minX), bar.maxX - tw), y: box.minY - 16),
                 font: tickFont, color: dim)
        }
        func marker(_ v: Double, above: Bool, color: NSColor) {
            let x = bar.minX + bar.width * CGFloat((min(max(v, -1), 1) + 1) / 2)
            let edge = above ? bar.maxY + 1 : bar.minY - 1
            let tip = above ? bar.maxY + 10 : bar.minY - 10
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x, y: edge))
            p.addLine(to: CGPoint(x: x - 6, y: tip))
            p.addLine(to: CGPoint(x: x + 6, y: tip))
            p.closeSubpath()
            ctx.addPath(p)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
        }
        marker(s.overall, above: true, color: .white)
        marker(s.lowOverall, above: false, color: bassColor)
        let key = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
        let kw = ("▼ ALL   ▲ BASS" as NSString).size(withAttributes: [.font: key]).width
        draw("▼ ALL", at: CGPoint(x: box.maxX - kw, y: box.maxY + 8), font: key, color: .white)
        draw("▲ BASS", at: CGPoint(x: box.maxX - kw + 44, y: box.maxY + 8), font: key, color: bassColor)
    }

    /// Per pixel column, the worst block in that column. Blank where it was too quiet to judge.
    private func worst(_ values: [Float], column c: Int, of cols: Int) -> Float? {
        let n = values.count
        let a = n * c / cols, b = min(n, max(a + 1, n * (c + 1) / cols))
        return values[a..<b].filter { !$0.isNaN }.min()
    }

    private func drawTimeline(_ s: StereoAnalysis.Result, duration: Double, in box: CGRect, ctx: CGContext) {
        ctx.setFillColor(NSColor(white: 1, alpha: 0.04).cgColor)
        ctx.fill(box)
        let zeroY = box.midY
        let cols = max(1, Int(box.width))
        if s.overTime.count > 1 {
            for c in 0..<cols {
                guard let v0 = worst(s.overTime, column: c, of: cols) else { continue }
                let v = CGFloat(min(max(v0, -1), 1))
                let h = box.height * 0.5 * v
                ctx.setFillColor((v < 0 ? fail : wideColor).withAlphaComponent(0.7).cgColor)
                ctx.fill(CGRect(x: box.minX + CGFloat(c), y: min(zeroY, zeroY + h), width: 1, height: abs(h)))
            }
        }
        if s.lowOverTime.count > 1 {
            let path = CGMutablePath()
            var penDown = false
            for c in 0..<cols {
                guard let v0 = worst(s.lowOverTime, column: c, of: cols) else { penDown = false; continue }
                let p = CGPoint(x: box.minX + CGFloat(c),
                                y: zeroY + box.height * 0.5 * CGFloat(min(max(v0, -1), 1)))
                penDown ? path.addLine(to: p) : path.move(to: p)
                penDown = true
            }
            ctx.addPath(path)
            ctx.setStrokeColor(bassColor.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.3).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: box.minX, y: zeroY)); ctx.addLine(to: CGPoint(x: box.maxX, y: zeroY))
        ctx.strokePath()

        let f = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
        draw("0:00", at: CGPoint(x: box.minX, y: box.minY - 13), font: f, color: dim)
        let end = String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
        let ew = (end as NSString).size(withAttributes: [.font: f]).width
        draw(end, at: CGPoint(x: box.maxX - ew, y: box.minY - 13), font: f, color: dim)
    }

    // MARK: - Text

    private func draw(_ s: String, at p: CGPoint, font: NSFont, color: NSColor) {
        (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func centered(_ s: String, in rect: CGRect, font: NSFont, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                             withAttributes: attrs)
    }

    /// Wraps within `width`, hanging from `top`; returns the height used.
    private func wrapped(_ s: String, x: CGFloat, top: CGFloat, width: CGFloat,
                         font: NSFont, color: NSColor, maxLines: Int) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let str = NSAttributedString(string: s, attributes: attrs)
        let bounds = CGSize(width: width, height: .greatestFiniteMagnitude)
        let line = NSAttributedString(string: "Ag", attributes: attrs)
            .boundingRect(with: bounds, options: [.usesLineFragmentOrigin]).height
        let natural = str.boundingRect(with: bounds, options: [.usesLineFragmentOrigin]).height
        let height = ceil(min(natural, line * CGFloat(maxLines)) + 0.5)
        str.draw(with: CGRect(x: x, y: top - height, width: width, height: height),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return height
    }
}
