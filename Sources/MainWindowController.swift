import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate {

    private let spectrogramView = SpectrogramView()
    private let cursorLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let progressBox = NSVisualEffectView()

    private let colormapPopup = NSPopUpButton()
    private let fftPopup = NSPopUpButton()
    private let overlapPopup = NSPopUpButton()
    private let windowPopup = NSPopUpButton()
    private let scaleControl = NSSegmentedControl(labels: ["Linear", "Log"],
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let poolControl = NSSegmentedControl(labels: Pooling.allCases.map(\.rawValue),
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let floorSlider = NSSlider()
    private let floorLabel = NSTextField(labelWithString: "−120 dB")
    private let gainSlider = NSSlider()
    private let gainLabel = NSTextField(labelWithString: "+0 dB")

    private var audio: AudioData?
    private var fileURL: URL?
    private var analysis = AnalysisSettings()
    private var render = RenderSettings()
    private var analysisToken = 0

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1420, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = AppInfo.name
        window.minSize = NSSize(width: 900, height: 480)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = false
        window.center()
        window.setFrameAutosaveName("NyquistMainWindow")
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    // MARK: - UI

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        let bar = buildControlBar()
        let status = buildStatusBar()

        spectrogramView.translatesAutoresizingMaskIntoConstraints = false
        spectrogramView.onCursor = { [weak self] c in self?.updateCursor(c) }
        spectrogramView.onFilesDropped = { [weak self] urls in
            if let first = urls.first { self?.open(url: first) }
        }

        content.addSubview(bar)
        content.addSubview(spectrogramView)
        content.addSubview(status)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 52),

            spectrogramView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            spectrogramView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            spectrogramView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            spectrogramView.bottomAnchor.constraint(equalTo: status.topAnchor),

            status.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 24),
        ])

        buildProgressOverlay(in: content)
        window.initialFirstResponder = spectrogramView
        syncControlsFromState()
    }

    private func group(_ caption: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: caption.uppercased())
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = NSColor(white: 0.55, alpha: 1)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func buildControlBar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.translatesAutoresizingMaskIntoConstraints = false

        let openButton = NSButton(title: "Open…", target: self, action: #selector(openDocument(_:)))
        openButton.bezelStyle = .rounded
        let fitButton = NSButton(title: "Fit", target: self, action: #selector(resetZoom))
        fitButton.bezelStyle = .rounded
        fitButton.toolTip = "Zoom out to the whole file (0)"
        let exportButton = NSButton(title: "Export…", target: self, action: #selector(exportImage))
        exportButton.bezelStyle = .rounded

        for cm in Colormap.all {
            let item = NSMenuItem(title: cm.name, action: nil, keyEquivalent: "")
            item.image = swatch(for: cm)
            colormapPopup.menu?.addItem(item)
        }
        colormapPopup.target = self
        colormapPopup.action = #selector(renderSettingChanged)

        for n in AnalysisSettings.fftSizes { fftPopup.addItem(withTitle: "\(n)") }
        fftPopup.target = self
        fftPopup.action = #selector(analysisSettingChanged)
        fftPopup.toolTip = "FFT size — larger means finer frequency detail and coarser time detail"

        for n in AnalysisSettings.overlaps { overlapPopup.addItem(withTitle: "\(n)×") }
        overlapPopup.target = self
        overlapPopup.action = #selector(analysisSettingChanged)
        overlapPopup.toolTip = "Window overlap — higher means finer time detail"

        for w in WindowFunction.allCases { windowPopup.addItem(withTitle: w.rawValue) }
        windowPopup.target = self
        windowPopup.action = #selector(analysisSettingChanged)

        poolControl.selectedSegment = 0
        poolControl.target = self
        poolControl.action = #selector(renderSettingChanged)
        poolControl.segmentStyle = .rounded
        poolControl.toolTip = "How to collapse the many analysis cells behind one pixel.\n"
            + "Avg: mean power — the energy actually there.\n"
            + "Typ: mean of the dB values, as Spek does — the level most of the time, so bursty highs look sparse.\n"
            + "Peak: the loudest cell — never hides a transient."

        scaleControl.selectedSegment = 0
        scaleControl.target = self
        scaleControl.action = #selector(scaleChanged)
        scaleControl.segmentStyle = .rounded

        floorSlider.minValue = -160
        floorSlider.maxValue = -40
        floorSlider.doubleValue = -120
        floorSlider.isContinuous = true
        floorSlider.target = self
        floorSlider.action = #selector(renderSettingChanged)
        floorSlider.widthAnchor.constraint(equalToConstant: 96).isActive = true
        floorSlider.toolTip = "Black point — the level that maps to the darkest color"

        // Negative gain lets the display match Spek, whose scale reads 12 dB lower.
        gainSlider.minValue = -24
        gainSlider.maxValue = 48
        gainSlider.doubleValue = 0
        gainSlider.isContinuous = true
        gainSlider.target = self
        gainSlider.action = #selector(renderSettingChanged)
        gainSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        gainSlider.toolTip = "Shift the whole image without re-analyzing. −12 dB matches Spek's scale."

        for l in [floorLabel, gainLabel] {
            l.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            l.textColor = NSColor(white: 0.7, alpha: 1)
            l.alignment = .center
        }

        func divider() -> NSView {
            let v = NSBox()
            v.boxType = .separator
            v.heightAnchor.constraint(equalToConstant: 28).isActive = true
            return v
        }

        let floorStack = NSStackView(views: [floorSlider, floorLabel])
        floorStack.orientation = .vertical
        floorStack.spacing = 0
        let gainStack = NSStackView(views: [gainSlider, gainLabel])
        gainStack.orientation = .vertical
        gainStack.spacing = 0

        let stack = NSStackView(views: [
            openButton, divider(),
            group("Color", colormapPopup),
            group("FFT", fftPopup),
            group("Overlap", overlapPopup),
            group("Window", windowPopup),
            group("Freq", scaleControl),
            group("Pixels", poolControl),
            divider(),
            group("Floor", floorStack),
            group("Gain", gainStack),
            divider(),
            fitButton, exportButton,
        ])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    private func swatch(for cm: Colormap) -> NSImage {
        let size = NSSize(width: 52, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        let lut = cm.lut()
        for x in 0..<Int(size.width) {
            let v = lut[Int(Double(x) / (size.width - 1) * 255)]
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                    green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1).setFill()
            NSRect(x: CGFloat(x), y: 0, width: 1, height: size.height).fill()
        }
        image.unlockFocus()
        return image
    }

    private func buildStatusBar() -> NSView {
        let box = NSVisualEffectView()
        box.material = .titlebar
        box.blendingMode = .withinWindow
        box.state = .active
        box.translatesAutoresizingMaskIntoConstraints = false

        for l in [cursorLabel, infoLabel] {
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            l.textColor = NSColor(white: 0.72, alpha: 1)
        }
        infoLabel.alignment = .right

        let stack = NSStackView(views: [cursorLabel, NSView(), infoLabel])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    private func buildProgressOverlay(in content: NSView) {
        progressBox.material = .hudWindow
        progressBox.blendingMode = .withinWindow
        progressBox.state = .active
        progressBox.wantsLayer = true
        progressBox.layer?.cornerRadius = 10
        progressBox.isHidden = true
        progressBox.translatesAutoresizingMaskIntoConstraints = false

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progressLabel.font = .systemFont(ofSize: 12)
        progressLabel.alignment = .center

        let stack = NSStackView(views: [progressLabel, progress])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        progressBox.addSubview(stack)
        content.addSubview(progressBox)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: progressBox.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: progressBox.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: progressBox.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: progressBox.bottomAnchor, constant: -16),
            progress.widthAnchor.constraint(equalToConstant: 240),
            progressBox.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            progressBox.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    private func syncControlsFromState() {
        colormapPopup.selectItem(withTitle: render.colormapName)
        fftPopup.selectItem(withTitle: "\(analysis.fftSize)")
        overlapPopup.selectItem(withTitle: "\(analysis.overlap)×")
        windowPopup.selectItem(withTitle: analysis.window.rawValue)
        scaleControl.selectedSegment = render.logFrequency ? 1 : 0
        poolControl.selectedSegment = Pooling.allCases.firstIndex(of: render.pooling) ?? 0
        floorSlider.doubleValue = render.dbFloor
        gainSlider.doubleValue = render.gain
        updateSliderLabels()
    }

    private func updateSliderLabels() {
        floorLabel.stringValue = String(format: "%.0f dB", render.dbFloor).replacingOccurrences(of: "-", with: "−")
        gainLabel.stringValue = String(format: "%+.0f dB", render.gain).replacingOccurrences(of: "-", with: "−")
    }

    // MARK: - Actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an audio file to analyze"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(url: url)
        }
    }

    func open(url: URL) { load(url: url, preserveZoom: false) }

    /// Re-reads the current file from disk, keeping settings and zoom. Pointed at a
    /// download in progress, each reload shows how much more has arrived.
    @objc func reload() {
        guard let url = fileURL else { NSSound.beep(); return }
        load(url: url, preserveZoom: true)
    }

    private func load(url: URL, preserveZoom: Bool) {
        showProgress("Decoding \(url.lastPathComponent)…", value: 0)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try AudioLoader.load(url: url)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.audio = data
                    self.fileURL = url
                    self.window?.title = url.lastPathComponent
                    self.window?.representedURL = url
                    self.spectrogramView.headerPath = url.path
                    self.reanalyze(preserveZoom: preserveZoom)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.hideProgress()
                    self?.presentError(error, title: "Could not open \(url.lastPathComponent)")
                }
            }
        }
    }

    @objc private func analysisSettingChanged() {
        analysis.fftSize = AnalysisSettings.fftSizes[fftPopup.indexOfSelectedItem]
        analysis.overlap = AnalysisSettings.overlaps[overlapPopup.indexOfSelectedItem]
        analysis.window = WindowFunction.allCases[windowPopup.indexOfSelectedItem]
        reanalyze(preserveZoom: true)
    }

    @objc private func renderSettingChanged() {
        render.pooling = Pooling.allCases[poolControl.selectedSegment]
        render.colormapName = colormapPopup.titleOfSelectedItem ?? render.colormapName
        render.dbFloor = floorSlider.doubleValue.rounded()
        render.gain = gainSlider.doubleValue.rounded()
        updateSliderLabels()
        spectrogramView.settings = render
    }

    @objc private func scaleChanged() {
        render.logFrequency = scaleControl.selectedSegment == 1
        spectrogramView.settings = render
        // Linear starts at DC; log has to start somewhere above it.
        var r = spectrogramView.range
        if render.logFrequency && r.f0 < 10 { r.f0 = 10 }
        if !render.logFrequency && r.f0 <= 10 { r.f0 = 0 }
        spectrogramView.setRange(r)
    }

    @objc func zoomIn() { spectrogramView.zoomTime(0.5) }
    @objc func zoomOut() { spectrogramView.zoomTime(2.0) }

    @objc func resetZoom() {
        spectrogramView.resetZoom()
        spectrogramView.invalidateHeat()
    }

    private func reanalyze(preserveZoom: Bool) {
        guard let audio else { return }
        analysisToken += 1
        let token = analysisToken
        let settings = analysis
        let saved = preserveZoom ? spectrogramView.range : nil

        showProgress("Analyzing — \(settings.fftSize)-point FFT, \(settings.overlap)× overlap…", value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = Date()
            let sg = Spectrogram.analyze(audio, settings: settings) { p in
                DispatchQueue.main.async {
                    guard let self, token == self.analysisToken else { return }
                    self.progress.doubleValue = p
                }
            }
            let elapsed = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                guard let self, token == self.analysisToken else { return }
                self.hideProgress()
                self.spectrogramView.settings = self.render
                self.spectrogramView.headerStream = audio.streamLine(
                    fftSize: settings.fftSize, window: settings.window.rawValue)
                self.spectrogramView.spectrogram = sg
                if let saved { self.spectrogramView.setRange(saved) }
                self.updateInfo(sg, audio: audio, elapsed: elapsed)
            }
        }
    }

    private func updateInfo(_ sg: Spectrogram, audio: AudioData, elapsed: TimeInterval) {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let frames = f.string(from: NSNumber(value: sg.frameCount)) ?? "\(sg.frameCount)"
        let binHz = sg.nyquist / Double(sg.binCount)
        let hopMs = Double(sg.hop) / sg.sampleRate * 1000
        var parts = ["\(frames) × \(sg.binCount)",
                     String(format: "%.2f Hz/bin", binHz),
                     String(format: "%.1f ms/col", hopMs),
                     audio.decodedVia,
                     String(format: "%.2fs", elapsed)]
        if let note = sg.reducedOverlapNote { parts.insert(note, at: 3) }
        if audio.isPartial {
            let pct = Int((audio.decodedDuration / max(audio.duration, 0.001) * 100).rounded(.down))
            parts.insert("PARTIAL FILE \(pct)% — \(SpectrogramRenderer.formatTime(audio.decodedDuration, step: 1)) of "
                         + "\(SpectrogramRenderer.formatTime(audio.duration, step: 1)) · ⌘W to reload", at: 0)
        }
        infoLabel.stringValue = parts.joined(separator: "  ·  ")
    }

    private func updateCursor(_ c: (Double, Double, Float)?) {
        guard let c else { cursorLabel.stringValue = ""; return }
        let m = Int(c.0) / 60
        let s = c.0 - Double(m * 60)
        let hz = c.1 >= 1000 ? String(format: "%.2f kHz", c.1 / 1000) : String(format: "%.0f Hz", c.1)
        let db = c.2 <= -199 ? "−∞ dB" : String(format: "%.1f dB", c.2).replacingOccurrences(of: "-", with: "−")
        cursorLabel.stringValue = String(format: "%d:%06.3f", m, s) + "   ·   " + hz + "   ·   " + db
    }

    // MARK: - Export

    @objc func exportImage() {
        guard let sg = spectrogramView.spectrogram, let audio else {
            NSSound.beep(); return
        }
        let panel = NSSavePanel()
        panel.message = "Export the spectrogram as a PNG image"
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.png] }
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "spectrogram"
        panel.nameFieldStringValue = "\(base) spectrogram.png"

        let accessory = ExportOptionsView(defaultSize: spectrogramView.bounds.size)
        panel.accessoryView = accessory

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let options = accessory.options
            let settings = self.render
            let range = self.spectrogramView.range
            let headerPath = self.fileURL?.path ?? ""
            let headerStream = audio.streamLine(fftSize: self.analysis.fftSize,
                                                window: self.analysis.window.rawValue)

            self.showProgress("Rendering \(options.width) × \(options.height)…", value: 0)
            self.progress.isIndeterminate = true
            self.progress.startAnimation(nil)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Exporter.write(to: url, spectrogram: sg, range: range, settings: settings,
                                       headerPath: headerPath, headerStream: headerStream,
                                       options: options)
                    DispatchQueue.main.async {
                        self.finishExport()
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.finishExport()
                        self.presentError(error, title: "Could not export the image")
                    }
                }
            }
        }
    }

    private func finishExport() {
        progress.stopAnimation(nil)
        progress.isIndeterminate = false
        hideProgress()
    }

    // MARK: - Helpers

    private func showProgress(_ text: String, value: Double) {
        progressLabel.stringValue = text
        progress.doubleValue = value
        progressBox.isHidden = false
    }

    private func hideProgress() { progressBox.isHidden = true }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
