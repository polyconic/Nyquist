import AppKit
import ImageIO
import UniformTypeIdentifiers

enum Exporter {

    struct Options {
        var width = 3840
        var height = 2160
        var includeAxes = true
        var includeHeader = true
        var entireFile = false
    }

    /// Guards against a request that would allocate more than ~1 GB of bitmap.
    static let maxDimension = 16384
    static let maxPixels = 220_000_000

    enum ExportError: LocalizedError {
        case tooLarge(Int, Int)
        case allocationFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let w, let h):
                return "\(w) × \(h) is larger than \(AppInfo.name) can render in one pass "
                     + "(limit \(maxDimension) px per side, \(maxPixels / 1_000_000) megapixels total)."
            case .allocationFailed:
                return "Could not allocate a bitmap that size. Try a smaller resolution."
            case .writeFailed(let m):
                return m
            }
        }
    }

    static func write(to url: URL,
                      spectrogram: Spectrogram,
                      range: ViewRange,
                      settings: RenderSettings,
                      headerPath: String,
                      headerStream: String,
                      options: Options) throws {
        let w = options.width, h = options.height
        guard w > 0, h > 0, w <= maxDimension, h <= maxDimension, w * h <= maxPixels else {
            throw ExportError.tooLarge(w, h)
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs, bitmapInfo: info.rawValue) else {
            throw ExportError.allocationFailed
        }

        let effectiveRange = options.entireFile ? ViewRange.full(spectrogram) : range
        let input = SpectrogramRenderer.ChartInput(
            spectrogram: spectrogram,
            range: effectiveRange,
            settings: settings,
            headerPath: headerPath,
            headerStream: headerStream,
            showHeader: options.includeHeader && options.includeAxes,
            showAxes: options.includeAxes)

        SpectrogramRenderer.drawChart(in: ctx, size: CGSize(width: w, height: h),
                                      input: input, pixelScale: 1)

        guard let image = ctx.makeImage() else { throw ExportError.allocationFailed }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.writeFailed("Could not create \(url.lastPathComponent).")
        }
        CGImageDestinationAddImage(dest, image, [
            kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.writeFailed("Could not write \(url.lastPathComponent).")
        }
    }
}

/// Accessory view shown inside the save panel.
final class ExportOptionsView: NSView {

    private let presetPopup = NSPopUpButton()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let axesCheck = NSButton(checkboxWithTitle: "Axes, legend and header", target: nil, action: nil)
    private let rangePopup = NSPopUpButton()
    private let note = NSTextField(labelWithString: "")

    private let presets: [(String, Int, Int)] = [
        ("Current window size", 0, 0),
        ("1920 × 1080  (HD)", 1920, 1080),
        ("2560 × 1440", 2560, 1440),
        ("3840 × 2160  (4K)", 3840, 2160),
        ("5120 × 2880  (5K)", 5120, 2880),
        ("7680 × 4320  (8K)", 7680, 4320),
        ("11520 × 6480", 11520, 6480),
        ("15360 × 8640  (16K)", 15360, 8640),
        ("Custom…", -1, -1),
    ]

    var viewSize: CGSize = CGSize(width: 1400, height: 900)

    init(defaultSize: CGSize) {
        super.init(frame: NSRect(x: 0, y: 0, width: 430, height: 132))
        viewSize = defaultSize

        for (title, _, _) in presets { presetPopup.addItem(withTitle: title) }
        presetPopup.selectItem(at: 3)
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)

        for f in [widthField, heightField] {
            f.alignment = .right
            f.formatter = intFormatter()
            f.target = self
            f.action = #selector(fieldChanged)
        }
        axesCheck.state = .on
        rangePopup.addItems(withTitles: ["Visible range", "Entire file"])
        note.font = .systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor

        func label(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.alignment = .right
            t.font = .systemFont(ofSize: 12)
            return t
        }

        let grid = NSGridView(views: [
            [label("Resolution:"), presetPopup],
            [label("Pixels:"), row()],
            [label("Time range:"), rangePopup],
            [NSGridCell.emptyContentView, axesCheck],
            [NSGridCell.emptyContentView, note],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).width = 84
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        presetChanged()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func row() -> NSView {
        let x = NSTextField(labelWithString: "×")
        x.font = .systemFont(ofSize: 12)
        widthField.widthAnchor.constraint(equalToConstant: 76).isActive = true
        heightField.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let stack = NSStackView(views: [widthField, x, heightField])
        stack.orientation = .horizontal
        stack.spacing = 6
        return stack
    }

    private func intFormatter() -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 16
        f.maximum = NSNumber(value: Exporter.maxDimension)
        return f
    }

    @objc private func presetChanged() {
        let p = presets[presetPopup.indexOfSelectedItem]
        let custom = p.1 == -1
        widthField.isEnabled = custom
        heightField.isEnabled = custom
        if p.1 == 0 {
            widthField.integerValue = Int(viewSize.width * 2)
            heightField.integerValue = Int(viewSize.height * 2)
        } else if !custom {
            widthField.integerValue = p.1
            heightField.integerValue = p.2
        }
        fieldChanged()
    }

    @objc private func fieldChanged() {
        let px = widthField.integerValue * heightField.integerValue
        let mb = Double(px * 4) / 1_048_576
        if px > Exporter.maxPixels {
            note.stringValue = "Too large — reduce below \(Exporter.maxPixels / 1_000_000) megapixels."
            note.textColor = .systemRed
        } else {
            note.stringValue = String(format: "%.1f megapixels, about %.0f MB while rendering.",
                                      Double(px) / 1_000_000, mb)
            note.textColor = .secondaryLabelColor
        }
    }

    var options: Exporter.Options {
        Exporter.Options(width: max(16, widthField.integerValue),
                         height: max(16, heightField.integerValue),
                         includeAxes: axesCheck.state == .on,
                         includeHeader: axesCheck.state == .on,
                         entireFile: rangePopup.indexOfSelectedItem == 1)
    }
}
