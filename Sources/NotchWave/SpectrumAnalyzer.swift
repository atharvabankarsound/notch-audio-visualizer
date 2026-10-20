import Accelerate
import os

/// A thread-safe snapshot of what the renderer needs for one frame.
struct AudioSnapshot: Sendable {
    /// Log-spaced frequency bands, 0…1. Index 0 is the lowest frequency.
    var bands: [Float]
    /// The most recent slice of the raw waveform, roughly −1…1.
    var waveform: [Float]
    /// RMS loudness of the latest analysis window (linear, 0…1).
    var level: Float
    /// `ProcessInfo.systemUptime` when this was computed. Capture APIs can simply stop
    /// delivering buffers when nothing plays, so the renderer treats old snapshots as silence.
    var timestamp: TimeInterval

    static func silent(bandCount: Int, waveformCount: Int) -> AudioSnapshot {
        AudioSnapshot(bands: Array(repeating: 0, count: bandCount),
                      waveform: Array(repeating: 0, count: waveformCount),
                      level: 0,
                      timestamp: 0)
    }
}

/// Turns a stream of audio samples into frequency bands with an FFT (Accelerate / vDSP).
///
/// The same idea as the vinyl visualizer: low frequencies end up at one end of the
/// band array and highs at the other, so the renderer can lay bass at the centre
/// of the notch and treble towards the outer edges.
final class SpectrumAnalyzer: @unchecked Sendable {
    static let fftSize = 2048
    static let hopSize = 512                 // analyse ~94 times a second at 48 kHz
    static let waveformCount = 96

    let bandCount: Int

    /// Extra gain in dB, set from the menu (Low / Normal / High sensitivity).
    var sensitivityDB: Float {
        get { inputLock.withLockUnchecked { _sensitivityDB } }
        set { inputLock.withLockUnchecked { _sensitivityDB = newValue } }
    }

    // MARK: Producer-side state (guarded by inputLock)
    private let inputLock = OSAllocatedUnfairLock()
    private var _sensitivityDB: Float = 0
    private var ring = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var writeIndex = 0
    private var samplesSinceAnalysis = 0
    private var sampleRate: Double = 48_000

    // FFT working buffers
    private let log2n = vDSP_Length(log2(Float(SpectrumAnalyzer.fftSize)))
    private let fftSetup: FFTSetup
    private let window: [Float]
    private var frame = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var windowed = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var real = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize / 2)
    private var imag = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize / 2)
    private var power = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize / 2)

    // MARK: Consumer-side state
    private let output: OSAllocatedUnfairLock<AudioSnapshot>

    init(bandCount: Int = 24) {
        self.bandCount = bandCount
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2(Float(Self.fftSize))), FFTRadix(kFFTRadix2)) else {
            fatalError("Could not create FFT setup")
        }
        fftSetup = setup
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                             count: Self.fftSize, isHalfWindow: false)
        output = OSAllocatedUnfairLock(initialState: .silent(bandCount: bandCount,
                                                             waveformCount: Self.waveformCount))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Latest analysis result. Cheap — safe to call every display frame.
    func snapshot() -> AudioSnapshot {
        output.withLock { $0 }
    }

    /// Clears everything (used when switching audio source).
    func reset() {
        inputLock.withLockUnchecked {
            for i in ring.indices { ring[i] = 0 }
            writeIndex = 0
            samplesSinceAnalysis = 0
        }
        output.withLock { $0 = .silent(bandCount: bandCount, waveformCount: Self.waveformCount) }
    }

    /// Feed samples from any audio thread.
    /// - Parameters:
    ///   - samples: pointer to Float32 samples
    ///   - count: number of frames
    ///   - stride: distance between consecutive frames (channel count for interleaved audio)
    func append(samples: UnsafePointer<Float>, count: Int, stride: Int = 1, sampleRate: Double) {
        guard count > 0 else { return }
        inputLock.withLockUnchecked {
            self.sampleRate = sampleRate
            let mask = Self.fftSize - 1
            for i in 0..<count {
                ring[writeIndex] = samples[i * stride]
                writeIndex = (writeIndex + 1) & mask
            }
            samplesSinceAnalysis += count
            if samplesSinceAnalysis >= Self.hopSize {
                samplesSinceAnalysis = 0
                analyze()
            }
        }
    }

    // MARK: - Analysis (runs inside inputLock)

    private func analyze() {
        let n = Self.fftSize
        let half = n / 2
        let mask = n - 1

        // 1. Unroll the ring buffer, oldest sample first.
        for i in 0..<n {
            frame[i] = ring[(writeIndex + i) & mask]
        }

        // 2. Waveform: the most recent ~10 ms, downsampled for drawing.
        let waveSpan = 512
        let step = waveSpan / Self.waveformCount
        var waveform = [Float](repeating: 0, count: Self.waveformCount)
        for i in 0..<Self.waveformCount {
            waveform[i] = frame[n - waveSpan + i * step]
        }

        // 3. Loudness.
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(n))

        // 4. Window + real FFT.
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { inPtr in
                    inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0  // Nyquist is packed here — ignore it
                power.withUnsafeMutableBufferPointer { powerPtr in
                    vDSP_zvmags(&split, 1, powerPtr.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        // Normalise so a full-scale sine is ~0 dB: zrip output for amplitude A with a
        // Hann window peaks around A·N/2, so divide power by (N/2)².
        var scale = 1 / Float((n / 2) * (n / 2))
        power.withUnsafeMutableBufferPointer { p in
            vDSP_vsmul(p.baseAddress!, 1, &scale, p.baseAddress!, 1, vDSP_Length(half))
        }

        // 5. Collapse bins into log-spaced bands (40 Hz → 16 kHz).
        let binWidth = Float(sampleRate) / Float(n)
        let minHz: Float = 40, maxHz: Float = 16_000
        let floorDB: Float = -72, ceilDB: Float = -12
        let tiltDB: Float = 15          // lift the treble so highs are as lively as bass
        var bands = [Float](repeating: 0, count: bandCount)

        for b in 0..<bandCount {
            let t0 = Float(b) / Float(bandCount)
            let t1 = Float(b + 1) / Float(bandCount)
            let lowHz = minHz * powf(maxHz / minHz, t0)
            let highHz = minHz * powf(maxHz / minHz, t1)
            var lo = Int(lowHz / binWidth)
            var hi = Int(highHz / binWidth)
            lo = max(1, min(lo, half - 1))
            hi = max(lo + 1, min(hi, half))

            var peak: Float = 0
            power.withUnsafeBufferPointer { p in
                vDSP_maxv(p.baseAddress! + lo, 1, &peak, vDSP_Length(hi - lo))
            }
            let db = 10 * log10f(peak + 1e-12) + tiltDB * t0 + _sensitivityDB
            bands[b] = min(1, max(0, (db - floorDB) / (ceilDB - floorDB)))
        }

        let result = AudioSnapshot(bands: bands, waveform: waveform, level: rms,
                                   timestamp: ProcessInfo.processInfo.systemUptime)
        output.withLock { $0 = result }
    }
}
