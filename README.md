# NotchWave

A live audio waveform that grows out of the MacBook notch. It listens to the microphone, everything your Mac is playing, or a single app, and draws a mirrored spectrum and waveform around the notch so it feels like a built-in macOS feature.

**Live demo:** https://atharvabankarsound.github.io/notch-audio-visualizer/ (a browser version running on a simulated MacBook screen)

## What it does

- Extends the notch with a black shape that matches its outline, so at rest it is invisible.
- When sound plays, the shape widens on a spring and smooth frosted-glass line waveforms rise out of flat lines either side of the notch, with faint echo lines trailing behind and a thin waveform along the bottom edge. The line style follows the `line_strip` grooves of the vinyl patch.
- Five waveform shapes, picked from thumbnails in Settings:
  - **Wrap** (default): one waveform that hugs the notch on its left, bottom and right sides and pushes outward with the sound, so the notch itself seems to breathe.
  - **Wave**: frosted-glass line waveforms either side of the notch.
  - **Bars**: glass capsules ("candles").
  - **Thread**: one fine line per side.
  - **Dots**: a small dot matrix.
- Bass sits next to the notch and treble reaches out to the tips, mirrored left and right. This is the same frequency layout as my Max/MSP and Jitter [rotating-vinyl visualiser](https://github.com/atharvabankarsound/vinyl-audio-visualizer) (lows at the centre, highs at the rim), unrolled along the menu bar.
- Settles back to a plain notch about 1.6 seconds after the sound stops.
- Menu bar icon to choose the source (All Computer Audio, Microphone, or a Single App) and the style (Glass, Aurora, System Accent).
- A Settings window (menu bar icon ▸ Settings…, or ⌘,) with the same controls as the demo website: waveform shape, colour, line thickness, wave height, width, glass, glow, echo lines, waveform under the notch, smoothing, how long it stays open after silence, sensitivity, and a live level meter.
- On a display without a notch, a virtual notch appears only while audio is playing.

## Requirements

- macOS 14 Sonoma or later
- Xcode 15 or later (or the Xcode command line tools)
- Any notched MacBook Air or MacBook Pro (other displays work with the virtual notch)

## Build and run

```bash
git clone https://github.com/atharvabankarsound/notch-audio-visualizer.git
cd notch-audio-visualizer
./scripts/build-app.sh
open build/NotchWave.app
```

To work on the code, open `Package.swift` in Xcode and press **Run**. When run from Xcode or Terminal, macOS asks for permissions on behalf of Xcode or Terminal instead of NotchWave.

### Permissions

| Source | Permission macOS asks for |
| --- | --- |
| Microphone | Microphone |
| All Computer Audio / Single App | Screen & System Audio Recording |

NotchWave only reads audio. The screen-recording permission is how macOS gates access to system audio; the app requests a 2×2 pixel video stream that it never uses. Audio is analysed in memory and discarded. Nothing is recorded or sent anywhere.

The build script signs the app ad hoc, so macOS may ask for permissions again after each rebuild.

## How it works

```
 Capture                    Analyse                          Draw
 ───────                    ───────                          ────
 AVAudioEngine (mic)   ┐    SpectrumAnalyzer                 NotchVisualizerView
 ScreenCaptureKit      ├──▶ 2048-point FFT (Accelerate)  ──▶ SwiftUI Canvas, every display frame
  (all audio / one app)┘    ~94 updates a second             spring physics for the shape
                            24 log bands, 40 Hz – 16 kHz     glass line waveforms + echoes
```

| File | Role |
| --- | --- |
| `NotchWaveApp.swift` | Entry point; runs as a menu bar app with no Dock icon |
| `AppDelegate.swift` | Menu bar menu, error alerts |
| `Settings.swift` | All user settings, saved in UserDefaults |
| `SettingsWindow.swift` | The System Settings–style window with sliders and toggles |
| `AudioCapture.swift` | Microphone and ScreenCaptureKit capture, source switching |
| `SpectrumAnalyzer.swift` | FFT, band mapping, thread-safe snapshots for the renderer |
| `NotchWindow.swift` | Reads the notch size from macOS and pins a click-through panel over it |
| `NotchVisualizerView.swift` | The island shape, bars, waveform lip and animation |
| `docs/index.html` | The browser demo (served by GitHub Pages) |

The notch size comes from `NSScreen.safeAreaInsets` and the `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` rectangles, so it fits every notched model without hard-coded sizes.

## Roadmap

- Hover to expand into a small now-playing panel
- Album-art colour tinting
- Metal renderer for lower energy use
- Launch at login

## Author

Atharva Bankar
