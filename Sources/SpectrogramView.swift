import AppKit

final class SpectrogramView: NSView {

    var spectrogram: Spectrogram? { didSet { resetZoom(); invalidateHeat() } }
    var settings = RenderSettings() { didSet { invalidateHeat() } }
    var headerPath = ""
    var headerStream = ""
    var placeholder = "Drop an audio file here"

    /// (time, hz, dB) under the pointer, or nil when it leaves the plot.
    var onCursor: ((Double, Double, Float)?) -> Void = { _ in }
    var onRangeChange: (ViewRange) -> Void = { _ in }
    var onFilesDropped: ([URL]) -> Void = { _ in }

    private(set) var range = ViewRange(t0: 0, t1: 1, f0: 0, f1: 1)
    private var fullRange = ViewRange(t0: 0, t1: 1, f0: 0, f1: 1)
    private var heat: CGImage?
    private var heatKey: String = ""
    private var cursor: CGPoint?
    private var dragOrigin: (point: CGPoint, range: ViewRange)?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Zoom state

    func resetZoom() {
        guard let sg = spectrogram else { return }
        fullRange = ViewRange.full(sg)
        range = fullRange
        if settings.logFrequency { range.f0 = 10 }
        onRangeChange(range)
    }

    func setRange(_ r: ViewRange) {
        range = r.clamped(to: fullRange, logFrequency: settings.logFrequency)
        invalidateHeat()
        onRangeChange(range)
    }

    func invalidateHeat() {
        heatKey = ""
        needsDisplay = true
    }

    var layout: ChartLayout {
        ChartLayout.compute(size: bounds.size, showHeader: true, showAxes: true)
    }

    // MARK: - Drawing

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2

        guard let sg = spectrogram else {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(bounds)
            let font = NSFont.systemFont(ofSize: 15)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor(white: 0.45, alpha: 1)]
            let size = (placeholder as NSString).size(withAttributes: attrs)
            (placeholder as NSString).draw(
                at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height / 2 - 8),
                withAttributes: attrs)
            return
        }

        let l = layout
        let pw = Int(l.plot.width * scale), ph = Int(l.plot.height * scale)
        let key = "\(range.t0),\(range.t1),\(range.f0),\(range.f1),\(settings.colormapName),"
            + "\(settings.dbFloor),\(settings.gain),\(settings.logFrequency),\(settings.pooling),\(pw)x\(ph),"
            + "\(ObjectIdentifier(sg).hashValue)"
        if key != heatKey {
            heat = SpectrogramRenderer.image(sg, range: range, settings: settings,
                                             pixelWidth: pw, pixelHeight: ph)
            heatKey = key
        }

        var input = SpectrogramRenderer.ChartInput(
            spectrogram: sg, range: range, settings: settings,
            headerPath: headerPath, headerStream: headerStream)
        input.heatImage = heat
        SpectrogramRenderer.drawChart(in: ctx, size: bounds.size, input: input, pixelScale: scale)

        if let c = cursor, l.plot.contains(c) {
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.32).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.move(to: CGPoint(x: c.x, y: l.plot.minY)); ctx.addLine(to: CGPoint(x: c.x, y: l.plot.maxY))
            ctx.move(to: CGPoint(x: l.plot.minX, y: c.y)); ctx.addLine(to: CGPoint(x: l.plot.maxX, y: c.y))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateHeat()
    }

    // MARK: - Pointer

    private func report(_ p: CGPoint) {
        guard let sg = spectrogram else { return onCursor(nil) }
        let l = layout
        guard l.plot.contains(p) else { return onCursor(nil) }
        let t = SpectrogramRenderer.time(atX: p.x, range: range, plot: l.plot)
        let hz = SpectrogramRenderer.frequency(atY: p.y, range: range, plot: l.plot,
                                               log: settings.logFrequency)
        let v = sg.value(frame: sg.frame(atTime: t), bin: sg.bin(atFrequency: hz))
        onCursor((t, hz, v))
    }

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        report(cursor!)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        cursor = nil
        onCursor(nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = (convert(event.locationInWindow, from: nil), range)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, spectrogram != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let l = layout
        let dx = Double(p.x - origin.point.x) / Double(max(l.plot.width, 1))
        let dy = Double(p.y - origin.point.y) / Double(max(l.plot.height, 1))

        var r = origin.range
        let tSpan = origin.range.t1 - origin.range.t0
        r.t0 -= tSpan * dx; r.t1 -= tSpan * dx

        if settings.logFrequency {
            let l0 = log10(max(origin.range.f0, 10)), l1 = log10(max(origin.range.f1, 20))
            let shift = (l1 - l0) * dy
            r.f0 = pow(10, l0 - shift); r.f1 = pow(10, l1 - shift)
        } else {
            let fSpan = origin.range.f1 - origin.range.f0
            r.f0 -= fSpan * dy; r.f1 -= fSpan * dy
        }
        setRange(r)
        cursor = p
        report(p)
    }

    override func mouseUp(with event: NSEvent) { dragOrigin = nil }

    override func scrollWheel(with event: NSEvent) {
        guard spectrogram != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let l = layout
        guard l.plot.contains(p) else { return super.scrollWheel(with: event) }

        // scrollingDeltaY is 0 for some event sources; deltaY is the legacy fallback.
        var raw = Double(event.scrollingDeltaY)
        if raw == 0 { raw = Double(event.deltaY) }
        let delta = event.hasPreciseScrollingDeltas ? raw / 90.0 : raw / 6.0
        guard delta != 0 else { return }
        let factor = pow(2.0, -Double(delta))

        // Shift zooms frequency, otherwise time; the point under the pointer stays put.
        var r = range
        if event.modifierFlags.contains(.shift) {
            if settings.logFrequency {
                let l0 = log10(max(range.f0, 10)), l1 = log10(max(range.f1, 20))
                let anchor = l0 + (l1 - l0) * Double((p.y - l.plot.minY) / max(l.plot.height, 1))
                r.f0 = pow(10, anchor - (anchor - l0) * factor)
                r.f1 = pow(10, anchor + (l1 - anchor) * factor)
            } else {
                let anchor = SpectrogramRenderer.frequency(atY: p.y, range: range, plot: l.plot, log: false)
                r.f0 = anchor - (anchor - range.f0) * factor
                r.f1 = anchor + (range.f1 - anchor) * factor
            }
        } else {
            let anchor = SpectrogramRenderer.time(atX: p.x, range: range, plot: l.plot)
            r.t0 = anchor - (anchor - range.t0) * factor
            r.t1 = anchor + (range.t1 - anchor) * factor
        }
        setRange(r)
        report(p)
    }

    override func magnify(with event: NSEvent) {
        guard spectrogram != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let l = layout
        guard l.plot.contains(p) else { return }
        let factor = 1.0 / (1.0 + Double(event.magnification))
        var r = range
        let anchor = SpectrogramRenderer.time(atX: p.x, range: range, plot: l.plot)
        r.t0 = anchor - (anchor - range.t0) * factor
        r.t1 = anchor + (range.t1 - anchor) * factor
        setRange(r)
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "0": resetZoom(); invalidateHeat()
        case "=", "+": zoomTime(0.5)
        case "-", "_": zoomTime(2.0)
        default: super.keyDown(with: event)
        }
    }

    func zoomTime(_ factor: Double) {
        var r = range
        let mid = (range.t0 + range.t1) / 2
        let half = (range.t1 - range.t0) / 2 * factor
        r.t0 = mid - half; r.t1 = mid + half
        setRange(r)
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let u = urls(from: sender)
        guard !u.isEmpty else { return false }
        onFilesDropped(u)
        return true
    }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
