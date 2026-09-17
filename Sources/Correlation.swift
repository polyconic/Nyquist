import Accelerate
import Foundation

/// Stereo phase analysis. +1 is mono, 0 is decorrelated, negative means the
/// channels fight each other and the low end will partly vanish when summed.
enum StereoAnalysis {

    struct Result {
        var overall: Double          // Pearson correlation across the whole file
        var overTime: [Float]        // per block, for the timeline strip
        var hopSeconds: Double
        var minimum: Double          // worst block, ignoring near-silence
        var fractionNegative: Double // share of blocks below zero
        var sideToMidDB: Double      // stereo width, side energy vs mid
        var vectorscope: [Float]     // size x size density, row 0 = top
        var vectorscopeSize: Int
        // Below lowBandHz only. This is the band that actually matters for mono
        // summing on a big system; out-of-phase highs are just width.
        var lowOverall: Double          // energy-weighted; what mono summing actually costs
        var lowMinimum: Double          // worst gated block, as context
        var lowFractionNegative: Double // share of low-band ENERGY that is phase-negative
        var lowOverTime: [Float] = []
        /// Left energy relative to right, in dB. Positive leans left.
        var balanceDB: Double = 0
    }

    static let lowBandHz = 150.0
    /// Blocks quieter than this, relative to the loudest block, are ignored.
    /// Correlation in near-silence is numerical noise, not a phase problem.
    static let gateBelowPeakDB = 40.0

    // Large enough for the stereo panel; row thumbnails scale it down.
    static let scopeSize = 512

    static func analyze(channels: [[Float]], sampleRate: Double) -> Result {
        // Mono files are trivially correlated; report that rather than dividing by zero.
        guard channels.count >= 2 else {
            return Result(overall: 1, overTime: [], hopSeconds: 0.1, minimum: 1,
                          fractionNegative: 0, sideToMidDB: -.infinity,
                          vectorscope: [Float](repeating: 0, count: scopeSize * scopeSize),
                          vectorscopeSize: scopeSize,
                          lowOverall: 1, lowMinimum: 1, lowFractionNegative: 0)
        }
        let l = channels[0], r = channels[1]
        let n = min(l.count, r.count)
        guard n > 0 else {
            return Result(overall: 0, overTime: [], hopSeconds: 0.1, minimum: 0,
                          fractionNegative: 0, sideToMidDB: -.infinity,
                          vectorscope: [Float](repeating: 0, count: scopeSize * scopeSize),
                          vectorscopeSize: scopeSize,
                          lowOverall: 1, lowMinimum: 1, lowFractionNegative: 0)
        }

        let overall = pearson(l, r, offset: 0, count: n)

        // 100 ms blocks, matching the loudness envelope so the strips line up.
        let block = max(1, Int(0.1 * sampleRate))
        let blockCount = max(1, n / block)
        let (overTime, gated) = correlationOverTime(l, r, n: n, block: block, blockCount: blockCount)

        let loud = gated.indices.filter { gated[$0] }.map { overTime[$0] }
        let minimum = Double(loud.min() ?? 1)
        let negative = loud.filter { $0 < 0 }.count
        let gatedCount = max(1, loud.count)

        // Mid/side energy ratio as a width figure.
        var midEnergy = 0.0, sideEnergy = 0.0, leftEnergy = 0.0, rightEnergy = 0.0
        l.withUnsafeBufferPointer { lb in
            r.withUnsafeBufferPointer { rb in
                let lp = lb.baseAddress!, rp = rb.baseAddress!
                for i in 0..<n {
                    let m = (lp[i] + rp[i]) * 0.5
                    let s = (lp[i] - rp[i]) * 0.5
                    midEnergy += Double(m * m)
                    sideEnergy += Double(s * s)
                    leftEnergy += Double(lp[i] * lp[i])
                    rightEnergy += Double(rp[i] * rp[i])
                }
            }
        }
        let width = midEnergy > 0 ? 10 * log10(max(sideEnergy, 1e-20) / midEnergy) : -.infinity

        // Low band, measured and gated the same way.
        let lowL = lowpass(lowpass(l, sampleRate), sampleRate)
        let lowR = lowpass(lowpass(r, sampleRate), sampleRate)
        let (lowOverTime, lowGated) = correlationOverTime(lowL, lowR, n: n, block: block,
                                                          blockCount: blockCount)
        let lowLoud = lowGated.indices.filter { lowGated[$0] }.map { lowOverTime[$0] }

        // Weight by energy. A dip during a breakdown where the bass is 30 dB down
        // costs nothing; the block count alone cannot tell you that.
        var negEnergy = 0.0, totalEnergy = 0.0
        lowL.withUnsafeBufferPointer { lb in
            let lp = lb.baseAddress!
            for j in 0..<blockCount {
                let off = j * block
                var ms: Float = 0
                vDSP_measqv(lp + off, 1, &ms, vDSP_Length(min(block, n - off)))
                totalEnergy += Double(ms)
                if lowGated[j] && lowOverTime[j] < 0 { negEnergy += Double(ms) }
            }
        }
        let lowNegEnergyFraction = totalEnergy > 0 ? negEnergy / totalEnergy : 0

        return Result(overall: overall,
                      overTime: overTime,
                      hopSeconds: Double(block) / sampleRate,
                      minimum: minimum,
                      fractionNegative: Double(negative) / Double(gatedCount),
                      sideToMidDB: width,
                      vectorscope: buildScope(l, r, count: n),
                      vectorscopeSize: scopeSize,
                      lowOverall: pearson(lowL, lowR, offset: 0, count: n),
                      lowMinimum: Double(lowLoud.min() ?? 1),
                      lowFractionNegative: lowNegEnergyFraction,
                      lowOverTime: lowOverTime,
                      balanceDB: leftEnergy > 0 && rightEnergy > 0
                          ? 10 * log10(leftEnergy / rightEnergy) : 0)
    }

    /// Per-block correlation plus a mask of which blocks are loud enough to mean
    /// anything, gated relative to the loudest block.
    private static func correlationOverTime(_ a: [Float], _ b: [Float], n: Int,
                                            block: Int, blockCount: Int) -> ([Float], [Bool]) {
        var levels = [Double](repeating: -300, count: blockCount)
        // NaN marks blocks too quiet to judge, so timelines can leave them blank.
        var values = [Float](repeating: .nan, count: blockCount)
        a.withUnsafeBufferPointer { ab in
            let ap = ab.baseAddress!
            for j in 0..<blockCount {
                let off = j * block
                let len = min(block, n - off)
                var ms: Float = 0
                vDSP_measqv(ap + off, 1, &ms, vDSP_Length(len))
                levels[j] = ms > 0 ? 10 * log10(Double(ms)) : -300
            }
        }
        let peak = levels.max() ?? -300
        let threshold = peak - gateBelowPeakDB
        var mask = [Bool](repeating: false, count: blockCount)
        for j in 0..<blockCount where levels[j] >= threshold {
            let off = j * block
            values[j] = Float(pearson(a, b, offset: off, count: min(block, n - off)))
            mask[j] = true
        }
        return (values, mask)
    }

    /// 2nd-order Butterworth low pass; call twice for 4th order.
    private static func lowpass(_ x: [Float], _ sampleRate: Double) -> [Float] {
        let w = tan(Double.pi * lowBandHz / sampleRate), q = 0.70710678
        let norm = 1 + w / q + w * w
        let b0 = w * w / norm, b1 = 2 * b0, b2 = b0
        let a1 = 2 * (w * w - 1) / norm, a2 = (1 - w / q + w * w) / norm
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let x0 = Double(x[i])
            let o = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = o
            y[i] = Float(o)
        }
        return y
    }

    private static func pearson(_ a: [Float], _ b: [Float], offset: Int, count: Int) -> Double {
        guard count > 1 else { return 1 }
        var dot: Float = 0, sa: Float = 0, sb: Float = 0
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                let x = ap.baseAddress! + offset, y = bp.baseAddress! + offset
                vDSP_dotpr(x, 1, y, 1, &dot, vDSP_Length(count))
                vDSP_svesq(x, 1, &sa, vDSP_Length(count))
                vDSP_svesq(y, 1, &sb, vDSP_Length(count))
            }
        }
        let denom = (Double(sa) * Double(sb)).squareRoot()
        return denom > 1e-20 ? Double(dot) / denom : 1
    }

    /// Lissajous density: mono lands on the vertical axis, out-of-phase on the horizontal.
    private static func buildScope(_ l: [Float], _ r: [Float], count: Int) -> [Float] {
        let size = scopeSize
        var grid = [Float](repeating: 0, count: size * size)
        let half = Double(size) / 2
        let k = 0.70710678  // 45-degree rotation

        l.withUnsafeBufferPointer { lb in
            r.withUnsafeBufferPointer { rb in
                let lp = lb.baseAddress!, rp = rb.baseAddress!
                grid.withUnsafeMutableBufferPointer { g in
                    for i in 0..<count {
                        // Digital silence says nothing about the stereo image, and a
                        // silent intro or unfinished download would swamp the center.
                        if lp[i] == 0 && rp[i] == 0 { continue }
                        let x = (Double(rp[i]) - Double(lp[i])) * k
                        let y = (Double(lp[i]) + Double(rp[i])) * k
                        let px = Int(half + x * half)
                        let py = Int(half - y * half)
                        guard px >= 0, px < size, py >= 0, py < size else { continue }
                        g[py * size + px] += 1
                    }
                }
            }
        }

        // Log compression — the center is orders of magnitude denser than the edges.
        var peak: Float = 0
        vDSP_maxv(grid, 1, &peak, vDSP_Length(grid.count))
        if peak > 0 {
            let scale = 1.0 / log1p(Double(peak))
            for i in 0..<grid.count where grid[i] > 0 {
                grid[i] = Float(log1p(Double(grid[i])) * scale)
            }
        }
        return grid
    }
}
