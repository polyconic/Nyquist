import Accelerate
import Foundation

enum WindowFunction: String, CaseIterable {
    case hann = "Hann"
    case hamming = "Hamming"
    case blackman = "Blackman"
    case blackmanHarris = "Blackman-Harris"
    case kaiser = "Kaiser"
    case rectangular = "Rectangular"

    func coefficients(_ n: Int) -> [Float] {
        var w = [Float](repeating: 0, count: n)
        switch self {
        case .hann:      vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        case .hamming:   vDSP_hamm_window(&w, vDSP_Length(n), 0)
        case .blackman:  vDSP_blkman_window(&w, vDSP_Length(n), 0)
        case .rectangular: w = [Float](repeating: 1, count: n)
        case .blackmanHarris:
            let (a0, a1, a2, a3) = (0.35875, 0.48829, 0.14128, 0.01168)
            for i in 0..<n {
                let t = 2.0 * Double.pi * Double(i) / Double(n - 1)
                w[i] = Float(a0 - a1 * cos(t) + a2 * cos(2 * t) - a3 * cos(3 * t))
            }
        case .kaiser:
            let beta = 10.0
            let denom = besselI0(beta)
            for i in 0..<n {
                let r = 2.0 * Double(i) / Double(n - 1) - 1.0
                w[i] = Float(besselI0(beta * (1.0 - r * r).squareRoot()) / denom)
            }
        }
        return w
    }

    private func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let half = x / 2
        for k in 1...40 {
            term *= (half / Double(k)) * (half / Double(k))
            sum += term
            if term < sum * 1e-17 { break }
        }
        return sum
    }
}

struct AnalysisSettings: Equatable {
    var fftSize: Int = 4096
    var overlap: Int = 4          // hop = fftSize / overlap
    var window: WindowFunction = .hann

    var hop: Int { max(1, fftSize / overlap) }

    static let fftSizes = [512, 1024, 2048, 4096, 8192, 16384, 32768]
    static let overlaps = [2, 4, 8, 16, 32]
}

/// Magnitudes in dBFS laid out as frameCount rows of binCount columns.
final class Spectrogram {
    let frameCount: Int
    let binCount: Int
    let hop: Int
    let sampleRate: Double
    let settings: AnalysisSettings
    let db: [Float]
    /// Set when the hop had to be widened to keep the matrix inside the memory ceiling.
    let reducedOverlapNote: String?

    var nyquist: Double { sampleRate / 2 }
    var duration: Double { Double(frameCount * hop) / sampleRate }

    /// Roughly 2 GB; beyond this the matrix alone starts to thrash on a 16 GB machine.
    private static let maxCells = 500_000_000

    static func analyze(_ audio: AudioData,
                        settings: AnalysisSettings,
                        progress: @escaping (Double) -> Void) -> Spectrogram {
        let n = settings.fftSize
        let bins = n / 2
        var hop = settings.hop
        var note: String? = nil

        let sampleCount = audio.samples.count
        var frames = max(1, (sampleCount - n) / hop + 1)
        if frames * bins > maxCells {
            let needed = Double(frames * bins) / Double(maxCells)
            let widened = Int((Double(hop) * needed).rounded(.up))
            hop = min(widened, n)
            frames = max(1, (sampleCount - n) / hop + 1)
            note = "overlap reduced to \(String(format: "%.1f", Double(n) / Double(hop)))x to fit in memory"
        }

        let windowCoeffs = settings.window.coefficients(n)
        var windowSum: Float = 0
        vDSP_sve(windowCoeffs, 1, &windowSum, vDSP_Length(n))
        if windowSum <= 0 { windowSum = Float(n) }

        var out = [Float](repeating: -200, count: frames * bins)
        let log2n = vDSP_Length(round(log2(Double(n))))

        let workers = min(ProcessInfo.processInfo.activeProcessorCount, 16)
        let chunkSize = max(1, (frames + workers - 1) / workers)
        let chunks = (frames + chunkSize - 1) / chunkSize

        let counter = Counter()
        let hopFinal = hop

        out.withUnsafeMutableBufferPointer { outBuf in
            let outBase = outBuf.baseAddress!
            audio.samples.withUnsafeBufferPointer { srcBuf in
                let src = srcBuf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
                    defer { vDSP_destroy_fftsetup(setup) }

                    var windowed = [Float](repeating: 0, count: n)
                    var realp = [Float](repeating: 0, count: bins)
                    var imagp = [Float](repeating: 0, count: bins)
                    var mags = [Float](repeating: 0, count: bins)
                    var reference: Float = 1.0
                    var floorValue: Float = 1e-10      // -200 dBFS
                    var ampScale = 1.0 / windowSum

                    let start = chunk * chunkSize
                    let end = min(start + chunkSize, frames)
                    guard start < end else { return }

                    for f in start..<end {
                        let offset = f * hopFinal
                        let avail = min(n, max(0, sampleCount - offset))
                        if avail == n {
                            vDSP_vmul(src + offset, 1, windowCoeffs, 1, &windowed, 1, vDSP_Length(n))
                        } else {
                            // Final partial frame: zero-pad rather than dropping it.
                            for i in 0..<n { windowed[i] = i < avail ? src[offset + i] * windowCoeffs[i] : 0 }
                        }

                        realp.withUnsafeMutableBufferPointer { rp in
                            imagp.withUnsafeMutableBufferPointer { ip in
                                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                                windowed.withUnsafeBufferPointer { wb in
                                    wb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
                                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins))
                                    }
                                }
                                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                                // zrip packs Nyquist into imagp[0]; clear it so bin 0 reads as DC only.
                                ip.baseAddress![0] = 0
                                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(bins))
                            }
                        }

                        vDSP_vsmul(mags, 1, &ampScale, &mags, 1, vDSP_Length(bins))
                        mags[0] *= 0.5                      // DC is not mirrored
                        vDSP_vthr(mags, 1, &floorValue, &mags, 1, vDSP_Length(bins))
                        vDSP_vdbcon(mags, 1, &reference, outBase + f * bins, 1, vDSP_Length(bins), 1)
                    }

                    let done = counter.increment()
                    progress(Double(done) / Double(chunks))
                }
            }
        }

        return Spectrogram(frameCount: frames, binCount: bins, hop: hop,
                           sampleRate: audio.sampleRate, settings: settings,
                           db: out, reducedOverlapNote: note)
    }

    private init(frameCount: Int, binCount: Int, hop: Int, sampleRate: Double,
                 settings: AnalysisSettings, db: [Float], reducedOverlapNote: String?) {
        self.frameCount = frameCount
        self.binCount = binCount
        self.hop = hop
        self.sampleRate = sampleRate
        self.settings = settings
        self.db = db
        self.reducedOverlapNote = reducedOverlapNote
    }

    func time(ofFrame f: Int) -> Double { Double(f * hop) / sampleRate }
    func frame(atTime t: Double) -> Int {
        min(max(Int(t * sampleRate / Double(hop)), 0), frameCount - 1)
    }
    func frequency(ofBin b: Int) -> Double { Double(b) * nyquist / Double(binCount) }
    func bin(atFrequency hz: Double) -> Int {
        min(max(Int(hz / nyquist * Double(binCount)), 0), binCount - 1)
    }

    func value(frame f: Int, bin b: Int) -> Float {
        guard f >= 0, f < frameCount, b >= 0, b < binCount else { return -200 }
        return db[f * binCount + b]
    }
}

/// concurrentPerform reports progress from many threads at once.
private final class Counter {
    private var value = 0
    private let lock = NSLock()
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
