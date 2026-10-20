import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

/// Where the waveform's audio comes from.
enum AudioSource: Equatable {
    case microphone
    case systemAudio
    case application(bundleID: String, name: String)

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "All Computer Audio"
        case .application(_, let name): return name
        }
    }
}

enum CaptureError: LocalizedError {
    case microphoneDenied
    case screenRecordingDenied
    case noDisplay
    case appNotFound(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "NotchWave needs microphone access. Turn it on in System Settings ▸ Privacy & Security ▸ Microphone."
        case .screenRecordingDenied:
            return "To hear computer audio, NotchWave needs “Screen & System Audio Recording” permission. Turn it on in System Settings ▸ Privacy & Security, then relaunch NotchWave."
        case .noDisplay:
            return "No display was available to capture audio from."
        case .appNotFound(let name):
            return "\(name) isn’t running any more, so its audio can’t be captured."
        }
    }

    var settingsURL: URL? {
        switch self {
        case .microphoneDenied:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .screenRecordingDenied:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        default:
            return nil
        }
    }
}

// MARK: - Microphone (AVAudioEngine)

final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let analyzer: SpectrumAnalyzer

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
    }

    func start() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw CaptureError.microphoneDenied }
        default:
            throw CaptureError.microphoneDenied
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        let analyzer = self.analyzer

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            // Non-interleaved: channel 0 is enough for a visualiser.
            analyzer.append(samples: channels[0], count: Int(buffer.frameLength), sampleRate: sampleRate)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

// MARK: - Computer audio / single-app audio (ScreenCaptureKit)

/// Captures what the Mac is playing. With `appBundleID` set, only that app's audio
/// is captured (e.g. just Spotify, just Safari) — ScreenCaptureKit filters audio
/// by application for us.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let analyzer: SpectrumAnalyzer
    private let queue = DispatchQueue(label: "notchwave.system-audio", qos: .userInteractive)
    private var stream: SCStream?

    /// Called on the main actor if macOS stops the stream (e.g. permission revoked).
    var onUnexpectedStop: (@MainActor (Error) -> Void)?

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
    }

    func start(appBundleID: String?, appName: String?) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            // The first call triggers the system permission prompt; a refusal lands here.
            throw CaptureError.screenRecordingDenied
        }

        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter: SCContentFilter
        if let bundleID = appBundleID {
            guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
                throw CaptureError.appNotFound(appName ?? bundleID)
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // We only want sound. Keep the (mandatory) video stream as tiny and slow as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Registering a screen output too stops ScreenCaptureKit logging dropped-frame errors.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }

        let sampleRate = asbd.mSampleRate
        let analyzer = self.analyzer

        try? sampleBuffer.withAudioBufferList { bufferList, _ in
            guard let first = bufferList.first, let data = first.mData else { return }
            let channels = max(Int(first.mNumberChannels), 1)
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            let samples = data.assumingMemoryBound(to: Float.self)
            // Non-interleaved → channels == 1 and stride 1; interleaved → stride over channels.
            analyzer.append(samples: samples, count: frames, stride: channels, sampleRate: sampleRate)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let handler = onUnexpectedStop
        Task { @MainActor in
            handler?(error)
        }
    }
}

// MARK: - Controller

/// Owns whichever capture is active and swaps between them.
@MainActor
final class AudioController {
    private let analyzer: SpectrumAnalyzer
    private var microphone: MicrophoneCapture?
    private var system: SystemAudioCapture?
    private var startTask: Task<Void, Never>?

    private(set) var source: AudioSource?
    var onError: ((Error) -> Void)?

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
    }

    func start(_ newSource: AudioSource) {
        stop()
        source = newSource
        analyzer.reset()

        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch newSource {
                case .microphone:
                    let mic = MicrophoneCapture(analyzer: analyzer)
                    self.microphone = mic
                    try await mic.start()

                case .systemAudio:
                    let capture = makeSystemCapture()
                    try await capture.start(appBundleID: nil, appName: nil)

                case .application(let bundleID, let name):
                    let capture = makeSystemCapture()
                    try await capture.start(appBundleID: bundleID, appName: name)
                }
            } catch {
                if !Task.isCancelled {
                    self.source = nil
                    self.onError?(error)
                }
            }
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        microphone?.stop()
        microphone = nil
        if let system {
            self.system = nil
            Task { await system.stop() }
        }
        source = nil
    }

    private func makeSystemCapture() -> SystemAudioCapture {
        let capture = SystemAudioCapture(analyzer: analyzer)
        capture.onUnexpectedStop = { [weak self] error in
            self?.source = nil
            self?.onError?(error)
        }
        system = capture
        return capture
    }
}
