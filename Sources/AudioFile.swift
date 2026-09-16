import AVFoundation
import Foundation

struct AudioData {
    var samples: [Float]          // mono mixdown, -1...1
    var sampleRate: Double
    var channelCount: Int
    var duration: Double { Double(samples.count) / sampleRate }
    var codecDescription: String  // e.g. "PCM signed 24-bit little-endian"
    var bitDepth: Int             // 0 when not meaningful (lossy codecs)
    var decodedVia: String        // "AVFoundation" or "ffmpeg"

    /// Header line in the style of Spek's stream summary.
    func streamLine(fftSize: Int, window: String) -> String {
        var parts = [codecDescription, "\(Int(sampleRate)) Hz"]
        if bitDepth > 0 { parts.append("\(bitDepth) bits") }
        parts.append(channelCount == 1 ? "mono" : "channel 1 / \(channelCount)")
        parts.append("W:\(fftSize)")
        parts.append("F:\(window)")
        return "Stream 1 / 1: " + parts.joined(separator: ", ")
    }
}

enum AudioLoadError: LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self { case .unreadable(let m): return m }
    }

    // Surfaced verbatim in the alert, so keep it actionable.
    static func combined(_ av: String, _ ff: String?) -> AudioLoadError {
        if let ff { return .unreadable("macOS could not decode this file (\(av)).\n\nffmpeg also failed: \(ff)") }
        return .unreadable("macOS could not decode this file.\n\n\(av)\n\nInstalling ffmpeg (brew install ffmpeg) adds support for formats macOS does not handle, such as Opus, WavPack and Monkey's Audio.")
    }
}

enum AudioLoader {

    static func load(url: URL) throws -> AudioData {
        do {
            return try loadNative(url: url)
        } catch {
            let avMessage = error.localizedDescription
            guard let tool = ffmpegPath() else { throw AudioLoadError.combined(avMessage, nil) }
            do {
                return try loadViaFFmpeg(url: url, ffmpeg: tool)
            } catch {
                throw AudioLoadError.combined(avMessage, error.localizedDescription)
            }
        }
    }

    // MARK: - AVFoundation

    private static func loadNative(url: URL) throws -> AudioData {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let channels = Int(file.fileFormat.channelCount)
        let total = Int(file.length)
        guard total > 0, channels > 0 else {
            throw AudioLoadError.unreadable("The file contains no audio frames.")
        }

        var mono = [Float](repeating: 0, count: total)
        let chunk: AVAudioFrameCount = 1 << 18
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else {
            throw AudioLoadError.unreadable("Could not allocate a decode buffer.")
        }

        var written = 0
        let scale = 1.0 / Float(channels)
        while written < total {
            try file.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let chans = buffer.floatChannelData else { break }
            // processingFormat is always deinterleaved float32, so sum across planes.
            for c in 0..<Int(buffer.format.channelCount) {
                let src = chans[c]
                if c == 0 {
                    for i in 0..<n { mono[written + i] = src[i] * scale }
                } else {
                    for i in 0..<n { mono[written + i] += src[i] * scale }
                }
            }
            written += n
        }
        if written < total { mono.removeLast(total - written) }

        let asbd = file.fileFormat.streamDescription.pointee
        return AudioData(samples: mono,
                         sampleRate: file.fileFormat.sampleRate,
                         channelCount: channels,
                         codecDescription: describe(asbd),
                         bitDepth: Int(asbd.mBitsPerChannel),
                         decodedVia: "AVFoundation")
    }

    private static func describe(_ d: AudioStreamBasicDescription) -> String {
        let id = d.mFormatID
        func fourCC(_ v: UInt32) -> String {
            let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                     UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
            return String(bytes: b, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
        }
        switch id {
        case kAudioFormatLinearPCM:
            let f = d.mFormatFlags
            let float = f & kAudioFormatFlagIsFloat != 0
            let signed = f & kAudioFormatFlagIsSignedInteger != 0
            let big = f & kAudioFormatFlagIsBigEndian != 0
            let kind = float ? "PCM float" : (signed ? "PCM signed" : "PCM unsigned")
            return "\(kind) \(d.mBitsPerChannel)-bit \(big ? "big" : "little")-endian"
        case kAudioFormatMPEGLayer3:     return "MPEG Layer 3 (MP3)"
        case kAudioFormatMPEG4AAC:       return "MPEG-4 AAC"
        case kAudioFormatMPEG4AAC_HE:    return "MPEG-4 HE-AAC"
        case kAudioFormatAppleLossless:  return "Apple Lossless (ALAC)"
        case kAudioFormatFLAC:           return "FLAC"
        case kAudioFormatOpus:           return "Opus"
        case kAudioFormatAC3:            return "AC-3"
        default:                         return "Codec '\(fourCC(id))'"
        }
    }

    // MARK: - ffmpeg fallback

    static func ffmpegPath() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return which("ffmpeg")
    }

    private static func which(_ tool: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", tool]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func loadViaFFmpeg(url: URL, ffmpeg: String) throws -> AudioData {
        let probe = probeWithFFprobe(url: url, near: ffmpeg)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-i", url.path, "-map", "0:a:0",
                       "-ac", "1", "-f", "f32le", "-acodec", "pcm_f32le", "-"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        var raw = Data()
        // Drain concurrently; a large file will otherwise deadlock on the 64K pipe buffer.
        let drain = DispatchQueue(label: "ffmpeg.drain")
        let done = DispatchSemaphore(value: 0)
        drain.async {
            while true {
                let d = out.fileHandleForReading.availableData
                if d.isEmpty { break }
                raw.append(d)
            }
            done.signal()
        }
        try p.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        done.wait()

        guard p.terminationStatus == 0, !raw.isEmpty else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AudioLoadError.unreadable(msg.isEmpty ? "ffmpeg produced no audio." : msg)
        }

        let samples = raw.withUnsafeBytes { buf -> [Float] in
            Array(buf.bindMemory(to: Float.self))
        }
        return AudioData(samples: samples,
                         sampleRate: probe.rate,
                         channelCount: probe.channels,
                         codecDescription: probe.codec,
                         bitDepth: probe.bits,
                         decodedVia: "ffmpeg")
    }

    private struct Probe { var rate: Double; var channels: Int; var codec: String; var bits: Int }

    private static func probeWithFFprobe(url: URL, near ffmpeg: String) -> Probe {
        var result = Probe(rate: 44100, channels: 2, codec: "Decoded by ffmpeg", bits: 0)
        let probePath = (ffmpeg as NSString).deletingLastPathComponent + "/ffprobe"
        guard FileManager.default.isExecutableFile(atPath: probePath) else { return result }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: probePath)
        p.arguments = ["-v", "quiet", "-select_streams", "a:0", "-show_entries",
                       "stream=sample_rate,channels,codec_long_name,bits_per_raw_sample",
                       "-of", "default=noprint_wrappers=1", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return result }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "sample_rate":          result.rate = Double(kv[1]) ?? result.rate
            case "channels":             result.channels = Int(kv[1]) ?? result.channels
            case "codec_long_name":      result.codec = kv[1]
            case "bits_per_raw_sample":  result.bits = Int(kv[1]) ?? 0
            default: break
            }
        }
        return result
    }
}
