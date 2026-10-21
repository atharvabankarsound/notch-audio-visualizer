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
    func step(now: TimeInterval, snapshot: AudioSnapshot, smoothing: CGFloat, hold: TimeInterval) {
        let dt = CGFloat(min(max(now - (lastTime ?? now), 0), 1.0 / 30.0))
        lastTime = now

        // A snapshot that hasn't been refreshed recently means the source went quiet.
        let fresh = now - snapshot.timestamp < 0.25
        let level = fresh ? snapshot.level : 0
        if level > 0.0025 { lastLoudTime = now }

        // Stay open briefly through gaps between songs so it doesn't flicker.
        let target: CGFloat = (now - lastLoudTime) < hold ? 1 : 0

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
            // More smoothing = slower response (same mapping as the website).
            let rate: CGFloat = goal > bands[i] ? 34 - smoothing * 2 : 12 - smoothing
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
                state.step(now: now, snapshot: analyzer.snapshot(),
                           smoothing: CGFloat(settings.smoothing), hold: settings.hold)
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

        // Wrap: one waveform around the notch's three sides. The notch barely grows sideways;
        // the waveform itself is the growth.
        if settings.shape == .wrap {
            let x0 = cx - notchWidth / 2 - 3 * e
            let x1 = cx + notchWidth / 2 + 3 * e
            let bottom = notchHeight + 2 * e
            context.fill(islandPath(x0: x0, x1: x1, bottom: bottom, e: e), with: .color(.black))
            if fade >= 0.01 { drawWrap(in: &context, x0: x0, x1: x1, bottom: bottom, e: e, fade: fade) }
            return
        }

        let wing = CGFloat(min(settings.width, Double(NotchLayout.maxWing))) * e
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

        // 3. The waveform in each wing. Bass sits next to the notch, treble at the outer tips,
        //    mirrored left/right — the vinyl layout unrolled along the menu bar.
        let midY = notchHeight / 2
        let maxHalf = min(notchHeight / 2 - 2, max(notchHeight / 2 - 6, 5) * CGFloat(settings.height / 100))
        for side in [-1.0, 1.0] as [CGFloat] {
            let edgeX = cx + side * notchWidth / 2
            switch settings.shape {
            case .wave:   drawWave(in: &context, side: side, edgeX: edgeX, wing: wing, midY: midY, maxHalf: maxHalf, fade: fade)
            case .bars:   drawBars(in: &context, side: side, edgeX: edgeX, wing: wing, midY: midY, maxHalf: maxHalf, fade: fade)
            case .thread: drawThread(in: &context, side: side, edgeX: edgeX, wing: wing, midY: midY, maxHalf: maxHalf, fade: fade)
            case .dots:   drawDots(in: &context, side: side, edgeX: edgeX, wing: wing, midY: midY, maxHalf: maxHalf, fade: fade)
            case .wrap:   break
            }
        }

        // 4. A thin time-domain waveform "lip" under the notch, mirrored from the centre outwards.
        guard settings.lipWaveform, drop > 2 else { return }
        let left = x0 + radius + 4
        let right = x1 - radius - 4
        let halfSpan = (right - left) / 2
        guard halfSpan > 4 else { return }

        let baseline = notchHeight + drop * 0.45
        let amplitude = drop * 0.38 * CGFloat(min(1.3, settings.height / 100))
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
        let clear = colourAt(1, alpha: 0)
        context.stroke(lip,
                       with: .linearGradient(Gradient(colors: [clear, colourAt(0, alpha: 0.75 * fade), clear]),
                                             startPoint: CGPoint(x: left, y: baseline),
                                             endPoint: CGPoint(x: right, y: baseline)),
                       style: StrokeStyle(lineWidth: 0.9 * settings.thickness, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Wave: frosted-glass envelope

    private func drawWave(in context: inout GraphicsContext, side: CGFloat, edgeX: CGFloat,
                          wing: CGFloat, midY: CGFloat, maxHalf: CGFloat, fade: CGFloat) {
        let start: CGFloat = 8
        let end = wing - 10
        guard end - start >= 8 else { return }
        let near = CGPoint(x: edgeX + side * start, y: midY)
        let far = CGPoint(x: edgeX + side * end, y: midY)
        let reveal = Double(min(1, (end - start) / 40) * fade)
        let th = CGFloat(settings.thickness)
        let glassAmount = settings.glass / 100

        func tint(_ alpha: Double) -> GraphicsContext.Shading {
            .linearGradient(gradient(alpha: alpha), startPoint: near, endPoint: far)
        }

        // Echo lines: thin and faint, like older grooves behind the current one.
        for (values, alpha) in settings.echoLines ? [(state.echo2, 0.16), (state.echo1, 0.3)] : [] {
            let env = envelope(values, start: start, end: end, side: side, edgeX: edgeX, midY: midY, maxHalf: maxHalf)
            var lines = Path()
            addSmooth(env.top, to: &lines, move: true)
            addSmooth(env.bottom, to: &lines, move: true)
            context.stroke(lines, with: tint(alpha * reveal), lineWidth: 0.7 * th)
        }

        let env = envelope(state.bands, start: start, end: end, side: side, edgeX: edgeX, midY: midY, maxHalf: maxHalf)

        // Frosted-glass body: tinted wash, then a white sheen that's brighter at the top.
        if glassAmount > 0 {
            var body = Path()
            addSmooth(env.top, to: &body, move: true)
            addSmooth(env.bottom.reversed(), to: &body, move: false)
            body.closeSubpath()
            let g = glassAmount * reveal
            context.fill(body, with: tint(0.22 * g))
            context.fill(body, with: .linearGradient(
                Gradient(stops: [.init(color: .white.opacity(0.45 * g), location: 0),
                                 .init(color: .white.opacity(0.07 * g), location: 0.45),
                                 .init(color: .white.opacity(0.2 * g), location: 1)]),
                startPoint: CGPoint(x: 0, y: midY - maxHalf), endPoint: CGPoint(x: 0, y: midY + maxHalf)))
        }

        var edges = Path()
        addSmooth(env.top, to: &edges, move: true)
        addSmooth(env.bottom, to: &edges, move: true)
        strokeWithGlow(edges, in: &context, shading: tint(0.95 * reveal), width: 1.1 * th, reveal: reveal)

        var highlight = Path()
        addSmooth(env.top, to: &highlight, move: true)
        context.stroke(highlight, with: .color(.white.opacity(0.7 * reveal)), lineWidth: 0.4 * th)
    }

    /// Upper and lower edges of one wing's waveform. Tapers to a point at both ends,
    /// so silence is a flat line — like the vinyl grooves.
    private func envelope(_ values: [CGFloat], start: CGFloat, end: CGFloat, side: CGFloat,
                          edgeX: CGFloat, midY: CGFloat, maxHalf: CGFloat) -> (top: [CGPoint], bottom: [CGPoint]) {
        let samples = 56
        var top: [CGPoint] = [], bottom: [CGPoint] = []
        top.reserveCapacity(samples + 1)
        bottom.reserveCapacity(samples + 1)
        for j in 0...samples {
            let u = CGFloat(j) / CGFloat(samples)
            let d = start + u * (end - start)
            let taper = ease(min(1, u / 0.1)) * ease(min(1, (1 - u) / 0.22))
            let h = (0.6 + sample(values, u) * maxHalf) * taper
            let x = edgeX + side * d
            top.append(CGPoint(x: x, y: midY - h))
            bottom.append(CGPoint(x: x, y: midY + h))
        }
        return (top, bottom)
    }

    // MARK: - Bars: glass capsules ("candles")

    private func drawBars(in context: inout GraphicsContext, side: CGFloat, edgeX: CGFloat,
                          wing: CGFloat, midY: CGFloat, maxHalf: CGFloat, fade: CGFloat) {
        let th = CGFloat(settings.thickness)
        let barWidth = 2.2 * th
        let pitch = barWidth + 2
        let start: CGFloat = 8
        let end = wing - 8
        let count = Int((CGFloat(settings.width) - 16) / pitch)
        guard count > 0 else { return }
        let glassAmount = settings.glass / 100

        for i in 0..<count {
            let d = start + CGFloat(i) * pitch
            let reveal = Double(min(1, (end - d - barWidth) / 12) * fade)
            if reveal <= 0 { break }
            let u = CGFloat(i) / CGFloat(max(count - 1, 1))
            let v = sample(state.bands, u)
            let h = max(barWidth, v * maxHalf * 2)
            let x = side < 0 ? edgeX - d - barWidth : edgeX + d
            let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
            let bar = Path(roundedRect: rect, cornerRadius: barWidth / 2)
            fillWithGlow(bar, in: &context, colour: colourAt(u, alpha: (0.55 + 0.45 * Double(v)) * reveal), reveal: reveal)
            if glassAmount > 0 && h > barWidth * 1.5 {
                context.fill(bar, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.6 * glassAmount * reveal), .white.opacity(0)]),
                    startPoint: CGPoint(x: x, y: rect.minY), endPoint: CGPoint(x: x, y: rect.midY)))
            }
        }
    }

    // MARK: - Thread: one fine line per side

    private func drawThread(in context: inout GraphicsContext, side: CGFloat, edgeX: CGFloat,
                            wing: CGFloat, midY: CGFloat, maxHalf: CGFloat, fade: CGFloat) {
        let start: CGFloat = 8
        let end = wing - 10
        guard end - start >= 8 else { return }
        let reveal = Double(min(1, (end - start) / 40) * fade)
        let t = CGFloat(state.lastTime ?? 0)
        var points: [CGPoint] = []
        for j in 0...72 {
            let u = CGFloat(j) / 72
            let d = start + u * (end - start)
            let v = sample(state.bands, u)
            let w = state.wave[min(state.wave.count - 1, Int(u * CGFloat(state.wave.count - 1)))] * 2
            // Its swing follows the spectrum; the detail comes from the real waveform.
            let swing = sin(d * 0.42 - t * 7) * 0.75 + w
            let taper = ease(min(1, u / 0.12)) * ease(min(1, (1 - u) / 0.2))
            points.append(CGPoint(x: edgeX + side * d, y: midY + max(-1, min(1, swing * v)) * maxHalf * taper))
        }
        var line = Path()
        addSmooth(points, to: &line, move: true)
        let shading = GraphicsContext.Shading.linearGradient(
            gradient(alpha: 0.95 * reveal),
            startPoint: CGPoint(x: edgeX + side * start, y: midY), endPoint: CGPoint(x: edgeX + side * end, y: midY))
        strokeWithGlow(line, in: &context, shading: shading, width: 1.2 * CGFloat(settings.thickness), reveal: reveal)
    }

    // MARK: - Dots: a small dot matrix, lit from the centre line outwards

    private func drawDots(in context: inout GraphicsContext, side: CGFloat, edgeX: CGFloat,
                          wing: CGFloat, midY: CGFloat, maxHalf: CGFloat, fade: CGFloat) {
        let dotRadius = 0.95 * CGFloat(settings.thickness)
        let pitch = max(3.4, dotRadius * 3.4)
        let start: CGFloat = 9
        let end = wing - 8
        let columns = Int((CGFloat(settings.width) - 17) / pitch)
        let rows = max(1, Int(maxHalf / pitch))
        guard columns > 0 else { return }

        for i in 0..<columns {
            let d = start + CGFloat(i) * pitch
            let reveal = Double(min(1, (end - d) / 10) * fade)
            if reveal <= 0 { break }
            let u = CGFloat(i) / CGFloat(max(columns - 1, 1))
            let v = sample(state.bands, u)
            let lit = v * CGFloat(rows)
            let x = edgeX + side * d
            for k in -rows...rows {
                let on = max(0, min(1, lit - CGFloat(abs(k)) + 1))
                let a: Double = k == 0
                    ? (0.35 + 0.65 * Double(min(1, v * 3))) * reveal
                    : Double(on) * (1 - Double(abs(k)) / Double(rows + 1) * 0.5) * reveal
                if a < 0.02 { continue }
                let dot = Path(ellipseIn: CGRect(x: x - dotRadius, y: midY + CGFloat(k) * pitch - dotRadius,
                                                 width: dotRadius * 2, height: dotRadius * 2))
                fillWithGlow(dot, in: &context, colour: colourAt(u, alpha: a), reveal: reveal * Double(min(1, v * 2)))
            }
        }
    }

    // MARK: - Wrap: one waveform around three sides of the notch

    private struct OutlinePoint { var point: CGPoint; var normal: CGVector; var f: CGFloat }

    /// Points along the notch's left side, bottom and right side, each with its outward normal.
    private func notchOutline(x0: CGFloat, x1: CGFloat, bottom: CGFloat, r: CGFloat, samples: Int) -> [OutlinePoint] {
        let sideLength = bottom - r
        let arc = .pi * r / 2
        let flat = x1 - x0 - 2 * r
        let total = 2 * sideLength + 2 * arc + flat
        var points: [OutlinePoint] = []
        points.reserveCapacity(samples + 1)
        for j in 0...samples {
            var s = CGFloat(j) / CGFloat(samples) * total
            let f = CGFloat(j) / CGFloat(samples)
            if s < sideLength {
                points.append(.init(point: CGPoint(x: x0, y: s), normal: CGVector(dx: -1, dy: 0), f: f)); continue
            }
            s -= sideLength
            if s < arc {
                let a = .pi - s / r
                points.append(.init(point: CGPoint(x: x0 + r + r * cos(a), y: bottom - r + r * sin(a)),
                                    normal: CGVector(dx: cos(a), dy: sin(a)), f: f)); continue
            }
            s -= arc
            if s < flat {
                points.append(.init(point: CGPoint(x: x0 + r + s, y: bottom), normal: CGVector(dx: 0, dy: 1), f: f)); continue
            }
            s -= flat
            if s < arc {
                let a = .pi / 2 - s / r
                points.append(.init(point: CGPoint(x: x1 - r + r * cos(a), y: bottom - r + r * sin(a)),
                                    normal: CGVector(dx: cos(a), dy: sin(a)), f: f)); continue
            }
            s -= arc
            points.append(.init(point: CGPoint(x: x1, y: max(0, bottom - r - s)), normal: CGVector(dx: 1, dy: 0), f: f))
        }
        return points
    }

    private func wrapLine(_ outline: [OutlinePoint], values: [CGFloat], amplitude: CGFloat, fade: CGFloat) -> [CGPoint] {
        outline.map { p in
            let u = abs(p.f - 0.5) * 2                  // 0 at the bottom centre (bass) → 1 at the top ends (treble)
            let taper = ease(min(1, (1 - u) / 0.14))
            let d = (1 + sample(values, u) * amplitude) * taper * fade
            return CGPoint(x: p.point.x + p.normal.dx * d, y: p.point.y + p.normal.dy * d)
        }
    }

    private func drawWrap(in context: inout GraphicsContext, x0: CGFloat, x1: CGFloat, bottom: CGFloat, e: CGFloat, fade: CGFloat) {
        let outline = notchOutline(x0: x0, x1: x1, bottom: bottom, r: cornerRadius(e: e), samples: 180)
        let amplitude = 13 * CGFloat(settings.height / 100)
        let th = CGFloat(settings.thickness)
        let glassAmount = settings.glass / 100
        let reveal = Double(fade)
        let start = CGPoint(x: x0 - amplitude - 4, y: bottom)
        let end = CGPoint(x: x1 + amplitude + 4, y: bottom)
        func tint(_ alpha: Double) -> GraphicsContext.Shading {
            .linearGradient(mirroredGradient(alpha: alpha), startPoint: start, endPoint: end)
        }

        let line = wrapLine(outline, values: state.bands, amplitude: amplitude, fade: fade)
        var shape = Path()
        addSmooth(line, to: &shape, move: true)
        shape.closeSubpath()

        // The notch grows with the sound: the whole shape is black…
        context.fill(shape, with: .color(.black))
        // …with a frosted-glass ribbon between the notch and the waveform.
        if glassAmount > 0 {
            var ribbon = context
            ribbon.clip(to: shape)
            ribbon.fill(shape, with: tint(0.18 * glassAmount * reveal))
            ribbon.fill(shape, with: .linearGradient(
                Gradient(colors: [.white.opacity(0), .white.opacity(0.22 * glassAmount * reveal)]),
                startPoint: CGPoint(x: 0, y: bottom - 4), endPoint: CGPoint(x: 0, y: bottom + amplitude)))
            context.fill(islandPath(x0: x0, x1: x1, bottom: bottom, e: e), with: .color(.black))
        }

        if settings.echoLines {
            for (values, alpha) in [(state.echo2, 0.16), (state.echo1, 0.32)] {
                var echo = Path()
                addSmooth(wrapLine(outline, values: values, amplitude: amplitude, fade: fade), to: &echo, move: true)
                context.stroke(echo, with: tint(alpha * reveal), lineWidth: 0.7 * th)
            }
        }

        var edge = Path()
        addSmooth(line, to: &edge, move: true)
        strokeWithGlow(edge, in: &context, shading: tint(0.95 * reveal), width: 1.2 * th, reveal: reveal)
        context.stroke(edge, with: .color(.white.opacity(0.55 * reveal)), lineWidth: 0.4 * th)
    }

    // MARK: - Shared helpers

    private func strokeWithGlow(_ path: Path, in context: inout GraphicsContext,
                                shading: GraphicsContext.Shading, width: CGFloat, reveal: Double) {
        let glow = settings.glow / 100
        if glow > 0 {
            var halo = context
            halo.addFilter(.blur(radius: 4 * glow))
            halo.stroke(path, with: .color(glowColour.opacity(0.9 * glow * reveal)), lineWidth: width * 1.8)
        }
        context.stroke(path, with: shading, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private func fillWithGlow(_ path: Path, in context: inout GraphicsContext, colour: Color, reveal: Double) {
        let glow = settings.glow / 100
        if glow > 0 && reveal > 0.02 {
            var halo = context
            halo.addFilter(.blur(radius: 3 * glow))
            halo.fill(path, with: .color(glowColour.opacity(0.7 * glow * reveal)))
        }
        context.fill(path, with: .color(colour))
    }

    private func sample(_ values: [CGFloat], _ u: CGFloat) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let f = max(0, min(1, u)) * CGFloat(values.count - 1)
        let i = min(Int(f), values.count - 1)
        let fr = f - CGFloat(i)
        return values[i] * (1 - fr) + values[min(i + 1, values.count - 1)] * fr
    }

    private func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

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

    /// Palette from the notch (bass) out to the tips (treble), per style.
    private var palette: [(location: CGFloat, colour: NSColor)] {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        switch settings.style {
        case .glass:
            return [(0, rgb(0.94, 0.96, 1.0)), (1, rgb(0.84, 0.88, 0.96))]
        case .aurora:
            return [(0, rgb(0.47, 0.91, 0.94)), (0.5, rgb(0.71, 0.66, 1.0)), (1, rgb(1.0, 0.61, 0.84))]
        case .accent:
            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? rgb(0.0, 0.48, 1.0)
            return [(0, accent), (1, accent.blended(withFraction: 0.45, of: .white) ?? accent)]
        }
    }

    private func colourAt(_ u: CGFloat, alpha: Double) -> Color {
        let pal = palette
        for i in 1..<pal.count where u <= pal[i].location {
            let t = (u - pal[i - 1].location) / (pal[i].location - pal[i - 1].location)
            let mixed = pal[i - 1].colour.blended(withFraction: max(0, min(1, t)), of: pal[i].colour) ?? pal[i].colour
            return Color(nsColor: mixed).opacity(alpha)
        }
        return Color(nsColor: pal[pal.count - 1].colour).opacity(alpha)
    }

    private func gradient(alpha: Double) -> Gradient {
        Gradient(stops: palette.map { .init(color: Color(nsColor: $0.colour).opacity(alpha), location: $0.location) })
    }

    /// Bass colour in the middle, treble colour at both ends (for Wrap).
    private func mirroredGradient(alpha: Double) -> Gradient {
        var stops: [Gradient.Stop] = []
        for (location, colour) in palette {
            let c = Color(nsColor: colour).opacity(alpha)
            stops.append(.init(color: c, location: 0.5 - location / 2))
            if location > 0 { stops.append(.init(color: c, location: 0.5 + location / 2)) }
        }
        return Gradient(stops: stops.sorted { $0.location < $1.location })
    }

    private var glowColour: Color {
        switch settings.style {
        case .glass: return .white
        case .aurora: return Color(red: 0.63, green: 0.75, blue: 1.0)
        case .accent: return Color(nsColor: .controlAccentColor)
        }
    }
}
