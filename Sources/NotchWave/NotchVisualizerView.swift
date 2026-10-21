import AppKit
import SwiftUI

/// Per-frame animation state. A class so the Canvas can update it every frame
/// without triggering SwiftUI view updates.
final class RenderState {
    var bands: [CGFloat]
    var echo1: [CGFloat]            // slower copies of the spectrum, drawn as faint
    var echo2: [CGFloat]            // "older grooves" behind the main waveform
    var wave: [CGFloat]
    var expansion: CGFloat = 0      // 0 = plain notch, 1 = fully grown
    var velocity: CGFloat = 0
    var lastTime: TimeInterval?
    var lastLoudTime: TimeInterval = -.infinity

    init(bandCount: Int, waveCount: Int) {
        bands = Array(repeating: 0, count: bandCount)
        echo1 = bands
        echo2 = bands
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

        // Spectrum: fast attack, slower release; echoes trail behind it.
        let k1 = 1 - exp(-5 * dt)
        let k2 = 1 - exp(-2.5 * dt)
        for i in bands.indices {
            let goal = fresh && i < snapshot.bands.count ? CGFloat(snapshot.bands[i]) : 0
            let rate: CGFloat = goal > bands[i] ? 24 : 6
            bands[i] += (goal - bands[i]) * (1 - exp(-rate * dt))
            echo1[i] += (bands[i] - echo1[i]) * k1
            echo2[i] += (echo1[i] - echo2[i]) * k2
        }

        for i in wave.indices {
            let goal = fresh && i < snapshot.waveform.count ? CGFloat(snapshot.waveform[i]) : 0
            wave[i] += (goal - wave[i]) * (1 - exp(-30 * dt))
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

        // 2. Glass rim: a faint highlight along the lower edge, brightest at the centre.
        let radius = cornerRadius(e: e)
        var rim = Path()
        rim.move(to: CGPoint(x: x0 + radius, y: bottom - 0.4))
        rim.addLine(to: CGPoint(x: x1 - radius, y: bottom - 0.4))
        context.stroke(rim,
                       with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.22 * fade), .white.opacity(0)]),
                                             startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)),
                       lineWidth: 0.6)

        // 3. Line waveforms in the two wings, like the line_strip grooves of the vinyl patch.
        //    Bass sits next to the notch, treble at the outer tips, mirrored left/right.
        let midY = notchHeight / 2
        let maxHalf = max(notchHeight / 2 - 6, 5)
        for side in [-1.0, 1.0] as [CGFloat] {
            drawWing(in: &context, side: side, cx: cx, notchWidth: notchWidth,
                     wing: wing, midY: midY, maxHalf: maxHalf, fade: fade)
        }

        // 4. A thin time-domain waveform "lip" under the notch, mirrored from the centre outwards.
        guard drop > 2 else { return }
        let left = x0 + radius + 4
        let right = x1 - radius - 4
        let halfSpan = (right - left) / 2
        guard halfSpan > 4 else { return }

        let baseline = notchHeight + drop * 0.45
        let amplitude = drop * 0.38
        var points: [CGPoint] = []
        var x = left
        while x <= right {
            let u = min(abs(x - cx) / halfSpan, 1)                // 0 at centre → 1 at the ends
            let idx = min(state.wave.count - 1, Int(u * CGFloat(state.wave.count - 1)))
            let taper = sin(.pi * (1 - u) / 2)                   // fades to flat at the ends
            let sample = max(-1, min(1, state.wave[idx] * 2.5))
            points.append(CGPoint(x: x, y: baseline + sample * amplitude * taper))
            x += 2
        }
        guard points.count > 2 else { return }
        var lip = Path()
        addSmooth(points, to: &lip, move: true)
        let stops = tintColours(alpha: 0.75 * fade)
        let near = stops.first ?? .white, far = stops.last ?? .white
        context.stroke(lip,
                       with: .linearGradient(Gradient(colors: [far.opacity(0), near, far.opacity(0)]),
                                             startPoint: CGPoint(x: left, y: baseline),
                                             endPoint: CGPoint(x: right, y: baseline)),
                       style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Waveforms

    private func drawWing(in context: inout GraphicsContext, side: CGFloat, cx: CGFloat, notchWidth: CGFloat,
                          wing: CGFloat, midY: CGFloat, maxHalf: CGFloat, fade: CGFloat) {
        let edgeX = cx + side * notchWidth / 2
        let start: CGFloat = 8
        let end = wing - 10
        guard end - start >= 8 else { return }
        let near = CGPoint(x: edgeX + side * start, y: midY)
        let far = CGPoint(x: edgeX + side * end, y: midY)
        let reveal = Double(min(1, (end - start) / 40) * fade)

        func tint(_ alpha: Double) -> GraphicsContext.Shading {
            .linearGradient(Gradient(colors: tintColours(alpha: alpha)), startPoint: near, endPoint: far)
        }

        // Echo lines: thin and faint, like older grooves behind the current one.
        for (values, alpha) in [(state.echo2, 0.16), (state.echo1, 0.3)] {
            let env = envelope(values, start: start, end: end, side: side, edgeX: edgeX, midY: midY, maxHalf: maxHalf)
            var lines = Path()
            addSmooth(env.top, to: &lines, move: true)
            addSmooth(env.bottom, to: &lines, move: true)
            context.stroke(lines, with: tint(alpha * reveal), lineWidth: 0.7)
        }

        let env = envelope(state.bands, start: start, end: end, side: side, edgeX: edgeX, midY: midY, maxHalf: maxHalf)

        // Frosted-glass body: tinted wash, then a white sheen that's brighter at the top.
        var body = Path()
        addSmooth(env.top, to: &body, move: true)
        addSmooth(env.bottom.reversed(), to: &body, move: false)
        body.closeSubpath()
        context.fill(body, with: tint(0.16 * reveal))
        context.fill(body, with: .linearGradient(
            Gradient(stops: [.init(color: .white.opacity(0.32 * reveal), location: 0),
                             .init(color: .white.opacity(0.05 * reveal), location: 0.45),
                             .init(color: .white.opacity(0.14 * reveal), location: 1)]),
            startPoint: CGPoint(x: 0, y: midY - maxHalf), endPoint: CGPoint(x: 0, y: midY + maxHalf)))

        // Edges: a soft blurred glow underneath, the tinted line, then a crisp highlight on top.
        var edges = Path()
        addSmooth(env.top, to: &edges, move: true)
        addSmooth(env.bottom, to: &edges, move: true)
        let round = StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)

        var glow = context
        glow.addFilter(.blur(radius: 2.5))
        glow.stroke(edges, with: .color(glowColour.opacity(0.55 * reveal)), lineWidth: 2)

        context.stroke(edges, with: tint(0.95 * reveal), style: round)

        var highlight = Path()
        addSmooth(env.top, to: &highlight, move: true)
        context.stroke(highlight, with: .color(.white.opacity(0.7 * reveal)), lineWidth: 0.45)
    }

    /// Upper and lower edges of one wing's waveform. Samples the bands smoothly and
    /// tapers to a point at both ends, so silence is a flat line — like the vinyl grooves.
    private func envelope(_ values: [CGFloat], start: CGFloat, end: CGFloat, side: CGFloat,
                          edgeX: CGFloat, midY: CGFloat, maxHalf: CGFloat) -> (top: [CGPoint], bottom: [CGPoint]) {
        let samples = 56
        let count = values.count
        var top: [CGPoint] = [], bottom: [CGPoint] = []
        top.reserveCapacity(samples + 1)
        bottom.reserveCapacity(samples + 1)
        func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

        for j in 0...samples {
            let u = CGFloat(j) / CGFloat(samples)
            let d = start + u * (end - start)
            let f = u * CGFloat(count - 1)
            let i = min(Int(f), count - 1)
            let fr = f - CGFloat(i)
            let v = values[i] * (1 - fr) + values[min(i + 1, count - 1)] * fr
            let taper = ease(min(1, u / 0.1)) * ease(min(1, (1 - u) / 0.22))
            let h = (0.6 + v * maxHalf) * taper
            let x = edgeX + side * d
            top.append(CGPoint(x: x, y: midY - h))
            bottom.append(CGPoint(x: x, y: midY + h))
        }
        return (top, bottom)
    }

    /// Smooth curve through points using midpoint quadratic smoothing.
    private func addSmooth(_ points: [CGPoint], to path: inout Path, move: Bool) {
        guard let first = points.first else { return }
        if move { path.move(to: first) } else { path.addLine(to: first) }
        if points.count > 2 {
            for i in 1..<(points.count - 1) {
                let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2,
                                  y: (points[i].y + points[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: points[i])
            }
        }
        if let last = points.last { path.addLine(to: last) }
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

    /// Tint from the notch edge (bass) out to the tip (treble).
    private func tintColours(alpha: Double) -> [Color] {
        switch settings.style {
        case .glass:
            return [Color(red: 0.94, green: 0.96, blue: 1.0).opacity(alpha),
                    Color(red: 0.84, green: 0.88, blue: 0.96).opacity(alpha)]
        case .aurora:
            return [Color(red: 0.47, green: 0.91, blue: 0.94).opacity(alpha),
                    Color(red: 0.71, green: 0.66, blue: 1.0).opacity(alpha),
                    Color(red: 1.0, green: 0.61, blue: 0.84).opacity(alpha)]
        case .accent:
            let accent = NSColor.controlAccentColor
            let light = accent.blended(withFraction: 0.45, of: .white) ?? accent
            return [Color(nsColor: accent).opacity(alpha), Color(nsColor: light).opacity(alpha)]
        }
    }

    private var glowColour: Color {
        switch settings.style {
        case .glass: return .white
        case .aurora: return Color(red: 0.63, green: 0.75, blue: 1.0)
        case .accent: return Color(nsColor: .controlAccentColor)
        }
    }
}
