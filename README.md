# Nyquist

A high-resolution audio spectrum analyzer for macOS. Built as a replacement for
Spek, which is an Intel-era app that Apple's transition away from Rosetta will
eventually strand.

Nyquist shares no code with Spek. The analysis engine is its own.

## Building

```
./build.sh
```

Produces `build/Nyquist.app` and `build/Nyquist-1.0.dmg`. Needs only the Xcode
Command Line Tools — no Xcode, no package manager, no dependencies.

To rename the app, change `APP_NAME` and `BUNDLE_ID` in `build.sh` and the
matching constants in `Sources/AppInfo.swift`.

## How it works

| Stage | Implementation |
|---|---|
| Decode | AVFoundation — WAV, AIFF, FLAC, MP3, AAC/M4A, ALAC, Ogg, CAF, Wave64, AC-3 |
| Decode fallback | ffmpeg, if installed, for Opus / WavPack / Monkey's Audio |
| Analysis | Accelerate/vDSP real FFT, parallelized across cores |
| Render | Hand-rolled color mapping into a CGImage, axes drawn with Core Graphics |

Decode and analysis of a 5-minute 24-bit/44.1k track take about 0.1 s combined;
redraws while dragging a slider take 15–35 ms.

### Calibration

Displayed values are per-bin amplitude in dBFS: a full-scale sine reads 0 dB.
Verified two ways —

* A synthetic −6.0 dBFS sine reads −6.19 dB with Blackman-Harris. The residual
  is scalloping loss, as expected for a tone off bin centre.
* Summing bin power across a real track and correcting for amplitude→RMS
  (−3.01 dB) and the Hann window's 1.5-bin noise bandwidth (−1.76 dB) gives
  −5.59 dBFS against ffmpeg `astats`' −5.56 dBFS. A 0.03 dB agreement.

Spek's display uses a different normalization and reads darker at the top end.
That is a display choice, not an accuracy difference. Use Floor and Gain to
match its look if you want it.

### Peak vs Avg

A 5-minute track at 4096/4× is about 13,750 analysis columns, which is roughly
11 columns behind every screen pixel. How those are collapsed matters:

* **Avg** — mean power. True sustained level. Matches what Spek shows.
* **Peak** — maximum. Never hides a transient or a stray spike, but reads about
  16 dB hotter on noise-like material at full zoom-out.

## Controls

| | |
|---|---|
| Scroll | Zoom time |
| Shift-scroll | Zoom frequency |
| Pinch | Zoom time |
| Drag | Pan |
| `0` or ⌘0 | Fit to window |
| ⌘+ / ⌘− | Zoom in / out |
| Drag and drop | Open a file |

**FFT** sets frequency resolution, **Overlap** sets time resolution. 32768/32×
is the finest; it costs memory but stays well under a second on a 5-minute file.

**Floor** is the black point. **Gain** brightens without re-analyzing. Neither
triggers a re-analysis, so both are live.

## Export

PNG up to 16384 px per side / 220 megapixels, at the current zoom or the whole
file, with or without axes. An 8K export takes under two seconds. Axes, labels
and the legend scale proportionally rather than being upscaled, so text stays
crisp at any size.

## Distribution

The app is ad-hoc signed, not notarized, so Gatekeeper will block the first
launch on another Mac. Control-click it in Applications, choose Open, confirm.
Or `xattr -dr com.apple.quarantine /Applications/Nyquist.app`.

Apple Silicon only. The Command Line Tools ship only the arm64 Swift runtime,
so an Intel slice would need full Xcode installed.
