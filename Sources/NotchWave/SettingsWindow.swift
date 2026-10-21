import AppKit
import SwiftUI

/// A System Settings–style window with the same controls as the demo website.
@MainActor
final class SettingsWindowController {
    private let settings: VisualizerSettings
    private let analyzer: SpectrumAnalyzer
    private weak var delegate: AppDelegate?
    private var window: NSWindow?

    init(settings: VisualizerSettings, analyzer: SpectrumAnalyzer, delegate: AppDelegate) {
        self.settings = settings
        self.analyzer = analyzer
        self.delegate = delegate
    }

    func show() {
        if window == nil {
            let root = SettingsView(settings: settings, analyzer: analyzer, input: InputModel(delegate: delegate))
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "NotchWave"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 460, height: 640))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Bridges the input picker to the app's audio controller.
@MainActor
final class InputModel: ObservableObject {
    private weak var delegate: AppDelegate?
    @Published var selection: String = "system"
    @Published var listening: Bool = true

    init(delegate: AppDelegate?) {
        self.delegate = delegate
        sync()
    }

    func sync() {
        switch delegate?.currentSource {
        case .microphone?: selection = "mic"; listening = true
        case .systemAudio?: selection = "system"; listening = true
        case .application?: selection = "app"; listening = true
        case nil: listening = false
        }
    }

    func choose(_ tag: String) {
        switch tag {
        case "mic": delegate?.select(.microphone)
        case "system": delegate?.select(.systemAudio)
        default: break   // single apps are picked from the menu bar list
        }
        selection = tag
        listening = true
    }

    func setListening(_ on: Bool) {
        delegate?.setListening(on)
        listening = on
    }

    var appName: String? {
        if case .application(_, let name)? = delegate?.currentSource { return name }
        return nil
    }
}

struct SettingsView: View {
    @ObservedObject var settings: VisualizerSettings
    let analyzer: SpectrumAnalyzer
    @StateObject var input: InputModel

    var body: some View {
        Form {
            Section("Input") {
                Picker("Listen to", selection: Binding(get: { input.selection }, set: { input.choose($0) })) {
                    Text("All Computer Audio").tag("system")
                    Text("Microphone").tag("mic")
                    if let name = input.appName { Text(name).tag("app") }
                }
                Toggle("Listening", isOn: Binding(get: { input.listening }, set: { input.setListening($0) }))
                LabeledContent("Level") { LevelMeter(analyzer: analyzer).frame(width: 180, height: 4) }
                SliderRow(title: "Sensitivity", value: $settings.sensitivityDB, range: -12...12, step: 1) {
                    ($0 > 0 ? "+" : "") + String(format: "%.0f dB", $0)
                }
                Text("To follow a single app, choose it from the menu bar icon under Single App.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Appearance") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Waveform")
                    ShapePicker(selection: $settings.shape)
                }
                Picker("Colour", selection: $settings.style) {
                    ForEach(WaveStyle.allCases) { Text($0.title).tag($0) }
                }
                SliderRow(title: "Line thickness", value: $settings.thickness, range: 0.5...3, step: 0.1) { String(format: "%.1f pt", $0) }
                SliderRow(title: "Wave height", value: $settings.height, range: 40...150, step: 5) { String(format: "%.0f%%", $0) }
                SliderRow(title: "Width", value: $settings.width, range: 60...160, step: 4) { String(format: "%.0f pt", $0) }
                SliderRow(title: "Glass", value: $settings.glass, range: 0...100, step: 5) { String(format: "%.0f%%", $0) }
                SliderRow(title: "Glow", value: $settings.glow, range: 0...100, step: 5) { String(format: "%.0f%%", $0) }
                Toggle("Echo lines", isOn: $settings.echoLines)
                Toggle("Waveform under notch", isOn: $settings.lipWaveform)
            }

            Section("Motion") {
                SliderRow(title: "Smoothing", value: $settings.smoothing, range: 1...10, step: 1) { String(format: "%.0f", $0) }
                SliderRow(title: "Stay open after silence", value: $settings.hold, range: 0.4...4, step: 0.2) { String(format: "%.1f s", $0) }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { settings.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 560)
        .onAppear { input.sync() }
    }
}

/// Thumbnail tiles like the Appearance picker in System Settings.
private struct ShapePicker: View {
    @Binding var selection: WaveShape

    var body: some View {
        HStack(spacing: 10) {
            ForEach(WaveShape.allCases) { shape in
                let selected = shape == selection
                Button { selection = shape } label: {
                    VStack(spacing: 5) {
                        ZStack(alignment: .top) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.35), Color(red: 0.1, green: 0.13, blue: 0.25)],
                                                     startPoint: .top, endPoint: .bottom))
                            UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3, style: .continuous)
                                .fill(.black)
                                .frame(width: 22, height: 7)
                            Image(systemName: shape.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.top, 13)
                        }
                        .frame(width: 60, height: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 0.5)
                        )
                        Text(shape.title)
                            .font(.caption)
                            .fontWeight(selected ? .semibold : .regular)
                            .foregroundStyle(selected ? Color.accentColor : .primary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(shape.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: 160)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }
}

/// Live input level, like the meter on the website.
private struct LevelMeter: View {
    let analyzer: SpectrumAnalyzer

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            let snap = analyzer.snapshot()
            let fresh = ProcessInfo.processInfo.systemUptime - snap.timestamp < 0.25
            let level = fresh ? min(1, Double(snap.level) * 4) : 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * level)
                }
            }
        }
    }
}
