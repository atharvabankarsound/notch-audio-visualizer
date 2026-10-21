import Foundation
import Combine

enum WaveStyle: String, CaseIterable, Identifiable {
    case glass, aurora, accent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: return "Glass"
        case .aurora: return "Aurora"
        case .accent: return "System Accent"
        }
    }
}

/// User-facing settings, persisted in UserDefaults.
/// The same controls (and defaults) as the settings window on the demo website.
final class VisualizerSettings: ObservableObject {
    private static let d = UserDefaults.standard

    // Appearance
    @Published var style: WaveStyle { didSet { Self.d.set(style.rawValue, forKey: "style") } }
    /// Line thickness multiplier (0.5 – 3).
    @Published var thickness: Double { didSet { Self.d.set(thickness, forKey: "thickness") } }
    /// Wave height in percent (40 – 150).
    @Published var height: Double { didSet { Self.d.set(height, forKey: "height") } }
    /// How far the shape grows out of each side of the notch, in points (60 – 160).
    @Published var width: Double { didSet { Self.d.set(width, forKey: "width") } }
    /// Frosted-glass fill strength in percent (0 – 100).
    @Published var glass: Double { didSet { Self.d.set(glass, forKey: "glass") } }
    /// Glow strength in percent (0 – 100).
    @Published var glow: Double { didSet { Self.d.set(glow, forKey: "glow") } }
    @Published var echoLines: Bool { didSet { Self.d.set(echoLines, forKey: "echoLines") } }
    @Published var lipWaveform: Bool { didSet { Self.d.set(lipWaveform, forKey: "lipWaveform") } }

    // Motion
    /// 1 = very responsive, 10 = very smooth.
    @Published var smoothing: Double { didSet { Self.d.set(smoothing, forKey: "smoothing") } }
    /// Seconds the notch stays open after the sound stops.
    @Published var hold: Double { didSet { Self.d.set(hold, forKey: "hold") } }

    // Input
    /// Extra gain applied before the bands are drawn (−12 … +12 dB).
    @Published var sensitivityDB: Double { didSet { Self.d.set(sensitivityDB, forKey: "sensitivityDB") } }

    init() {
        let d = Self.d
        func number(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) == nil ? fallback : d.double(forKey: key) }
        func flag(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }

        style = WaveStyle(rawValue: d.string(forKey: "style") ?? "") ?? .glass
        thickness = number("thickness", 1)
        height = number("height", 100)
        width = number("width", 112)
        glass = number("glass", 70)
        glow = number("glow", 60)
        echoLines = flag("echoLines", true)
        lipWaveform = flag("lipWaveform", true)
        smoothing = number("smoothing", 5)
        hold = number("hold", 1.6)
        sensitivityDB = number("sensitivityDB", 0)
    }

    func resetToDefaults() {
        style = .glass; thickness = 1; height = 100; width = 112; glass = 70; glow = 60
        echoLines = true; lipWaveform = true; smoothing = 5; hold = 1.6; sensitivityDB = 0
    }

    // The last chosen audio source, so NotchWave picks up where you left it.
    var savedSource: AudioSource {
        get {
            let d = Self.d
            switch d.string(forKey: "source.kind") {
            case "mic": return .microphone
            case "app":
                if let id = d.string(forKey: "source.bundleID") {
                    return .application(bundleID: id, name: d.string(forKey: "source.name") ?? id)
                }
                return .systemAudio
            default: return .systemAudio
            }
        }
        set {
            let d = Self.d
            switch newValue {
            case .microphone:
                d.set("mic", forKey: "source.kind")
            case .systemAudio:
                d.set("system", forKey: "source.kind")
            case .application(let id, let name):
                d.set("app", forKey: "source.kind")
                d.set(id, forKey: "source.bundleID")
                d.set(name, forKey: "source.name")
            }
        }
    }
}
