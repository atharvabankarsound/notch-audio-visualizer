import AppKit
import SwiftUI

/// Per-frame animation state. A class so the Canvas can update it every frame
/// without triggering SwiftUI view updates.
final class RenderState {
    var bands: [CGFloat]
    var wave: [CGFloat]
    var expansion: CGFloat = 0      // 0 = plain notch, 1 = fully grown
    var velocity: CGFloat = 0
    var lastTime: TimeInterval?
    var lastLoudTime: TimeInterval = -.infinity

    init(bandCount: Int, waveCount: Int) {
        bands = Array(repeating: 0, count: bandCount)
        wave = Array(repeating: 0, count: waveCount)
    }

    /// Advances springs and smoothing by one display frame.
    func step(now: TimeInterval, snapshot: AudioSnapshot) {
        let dt = CGFloat(min(max(now - (lastTime ?? now), 0), 1.0 / 30.0))
        lastTime = now

        // A snapshot that hasn't been refreshed recently means the source went quiet.
        let fresh = now - snapshot.timestamp < 0.25
        let level = fresh ? snapshot.level : 0
        if level > 0.0025 { lastLoudTime = now }

        // Stay open briefly through gaps between songs so it doesn't flicker.
        let target: CGFloat = (now - lastLoudTime) < 1.6 ? 1 : 0

        // Slightly under-damped spring → the gentle overshoot Apple's animations have.
        let stiffness: CGFloat = 170
        let damping: CGFloat = 19
        let acceleration = stiffness * (target - expansion) - damping * velocity
        velocity += acceleration * dt
        expansion += velocity * dt

        // Bars: fast attack, slower release.
        for i in bands.indices {
            let goal = fresh && i < snapshot.bands.count ? CGFloat(snapshot.bands[i]) : 0
            let rate: CGFloat = goal > bands[i] ? 30 : 7
            bands[i] += (goal - bands[i]) * (1 - exp(-rate * dt))
        }

        for i in wave.indices {
            let goal = fresh && i < snapshot.waveform.count ? CGFloat(snapshot.waveform[i]) : 0
            wave[i] += (goal - wave[i]) * (1 - exp(-40 * dt))
        }
    }
}

struct NotchVisualizerView: View {
    let analyzer: SpectrumAnalyzer
    let geometry: NotchGeometry
    @ObservedObject var settings: VisualizerSettings

    @State private var state: RenderState

    init(analyzer: SpectrumAnalyzer, geometry: NotchGeometry, settings: VisualizerSettings) {
        self.analyzer = analyzer
        self.geometry = geometry
        self.settings = settings
        _state = State(initialValue: RenderState(bandCount: analyzer.bandCount,
                                                 waveCount: SpectrumAnalyzer.waveformCount))
    }

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                let now = ProcessInfo.processInfo.systemUptime
                state.step(now: now, snapshot: analyzer.snapshot())
                draw(in: &context, size: size)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let e = max(0, state.expansion)              // allow overshoot above 1, not below 0
        let fade = min(1, e)

        // On a real notch the shape always exists (it's black on black, so invisible at rest).
        // On screens without a notch, the virtual notch grows out of nothing.
        let notchWidth = geometry.hasNotch ? geometry.notchSize.width : geometry.notchSize.width * fade
        let notchHeight = geometry.notchSize.height
        if !geometry.hasNotch && fade < 0.01 { return }

        let cx = size.width / 2
        let wing = NotchLayout.maxWing * e
        let drop = NotchLayout.maxDrop * e
        let x0 = cx - notchWidth / 2 - wing
        let x1 = cx + notchWidth / 2 + wing
        let bottom = notchHeight + drop

        // 1. The black island: an extension of the notch's own outline.
        context.fill(islandPath(x0: x0, x1: x1, bottom: bottom, e: e), with: .color(.black))
        guard fade > 0.01 else { return }

        // 2. Spectrum bars in the two wings. Bass sits next to the notch, treble at the
        //    outer tips, mirrored left/right — the vinyl layout unrolled along the notch.
        let barWidth: CGFloat = 2.4
        let pitch: CGFloat = 4.2
        let inset: CGFloat = 9
        let maxBarHeight = max(notchHeight - 14, 8)
        let midY = notchHeight / 2
        let count = state.bands.count

        for i in 0..<count {
            let distance = inset + CGFloat(i) * pitch
            let reveal = (wing - 8 - distance - barWidth) / 14   // bars appear as the wing grows
            guard reveal > 0 else { break }
            let alpha = min(1, reveal) * fade

            let value = state.bands[i]
            let barHeight = max(barWidth, value * maxBarHeight)
            let colour = barColour(index: i, of: count, value: value).opacity(Double(alpha))

            for side in [-1.0, 1.0] as [CGFloat] {
                let x = side < 0
                    ? cx - notchWidth / 2 - distance - barWidth
                    : cx + notchWidth / 2 + distance
                let rect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(colour))
            }
        }

        // 3. A thin waveform "lip" along the bottom edge, mirrored from the centre outwards.
        guard drop > 2 else { return }
        let radius = cornerRadius(e: e)
        let left = x0 + radius + 4
        let right = x1 - radius - 4
        let halfSpan = (right - left) / 2
        guard halfSpan > 4 else { return }

        let baseline = notchHeight + drop * 0.5
        let amplitude = drop * 0.42
        var line = Path()
        var x = left
        var first = true
        while x <= right {
            let u = abs(x - cx) / halfSpan                       // 0 at centre → 1 at the ends
            let idx = min(state.wave.count - 1, Int(u * CGFloat(state.wave.count - 1)))
            let taper = sin(.pi * (1 - u) / 2)                   // fades to flat at the ends
            let sample = max(-1, min(1, state.wave[idx] * 2.5))
            let point = CGPoint(x: x, y: baseline + sample * amplitude * taper)
            if first { line.move(to: point); first = false } else { line.addLine(to: point) }
            x += 1.5
        }
        context.stroke(line,
                       with: .linearGradient(lipGradient(alpha: 0.85 * fade),
                                             startPoint: CGPoint(x: left, y: baseline),
                                             endPoint: CGPoint(x: right, y: baseline)),
                       lineWidth: 1.2)
    }

    private func cornerRadius(e: CGFloat) -> CGFloat {
        9 + 3 * min(1, e)
    }

    /// Notch-style outline: flat along the top edge of the screen, small concave "ears"
    /// where it meets the menu bar, continuous rounded corners at the bottom.
    private func islandPath(x0: CGFloat, x1: CGFloat, bottom: CGFloat, e: CGFloat) -> Path {
        let ear = NotchLayout.ear
        let r = cornerRadius(e: e)
        let k: CGFloat = 0.45   // control-point factor: smoother than a circular arc
        var p = Path()
        p.move(to: CGPoint(x: x0 - ear, y: 0))
        p.addCurve(to: CGPoint(x: x0, y: ear),
                   control1: CGPoint(x: x0 - ear * k, y: 0),
                   control2: CGPoint(x: x0, y: ear * (1 - k)))
        p.addLine(to: CGPoint(x: x0, y: bottom - r))
        p.addCurve(to: CGPoint(x: x0 + r, y: bottom),
                   control1: CGPoint(x: x0, y: bottom - r * k),
                   control2: CGPoint(x: x0 + r * k, y: bottom))
        p.addLine(to: CGPoint(x: x1 - r, y: bottom))
        p.addCurve(to: CGPoint(x: x1, y: bottom - r),
                   control1: CGPoint(x: x1 - r * k, y: bottom),
                   control2: CGPoint(x: x1, y: bottom - r * k))
        p.addLine(to: CGPoint(x: x1, y: ear))
        p.addCurve(to: CGPoint(x: x1 + ear, y: 0),
                   control1: CGPoint(x: x1, y: ear * (1 - k)),
                   control2: CGPoint(x: x1 + ear * k, y: 0))
        p.closeSubpath()
        return p
    }

    // MARK: - Colour

    private func barColour(index: Int, of count: Int, value: CGFloat) -> Color {
        let t = Double(index) / Double(max(count - 1, 1))
        let glow = 0.55 + 0.45 * Double(value)
        switch settings.style {
        case .aurora:
            // Cyan for bass → violet → pink for treble.
            return Color(hue: 0.52 + 0.38 * t, saturation: 0.62, brightness: 1).opacity(glow)
        case .mono:
            return Color.white.opacity(0.35 + 0.6 * Double(value))
        case .accent:
            return Color(nsColor: .controlAccentColor).opacity(glow)
        }
    }

    private func lipGradient(alpha: Double) -> Gradient {
        switch settings.style {
        case .aurora:
            // Mirrored: treble colour at both ends, bass colour in the middle.
            let bass = Color(hue: 0.52, saturation: 0.62, brightness: 1).opacity(alpha)
            let treble = Color(hue: 0.90, saturation: 0.62, brightness: 1).opacity(alpha)
            return Gradient(colors: [treble.opacity(0), treble, bass, treble, treble.opacity(0)])
        case .mono:
            let w = Color.white.opacity(alpha * 0.8)
            return Gradient(colors: [w.opacity(0), w, w, w.opacity(0)])
        case .accent:
            let a = Color(nsColor: .controlAccentColor).opacity(alpha)
            return Gradient(colors: [a.opacity(0), a, a, a.opacity(0)])
        }
    }
}
