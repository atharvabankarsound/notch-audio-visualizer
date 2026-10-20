import AppKit
import Combine

enum WaveStyle: String, CaseIterable {
    case aurora, mono, accent

    var title: String {
        switch self {
        case .aurora: return "Aurora"
        case .mono: return "Mono"
        case .accent: return "System Accent"
        }
    }
}

enum Sensitivity: String, CaseIterable {
    case low, normal, high

    var title: String { rawValue.capitalized }

    var gainDB: Float {
        switch self {
        case .low: return -6
        case .normal: return 0
        case .high: return 9
        }
    }
}

/// User-facing settings, persisted in UserDefaults.
final class VisualizerSettings: ObservableObject {
    @Published var style: WaveStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "style") }
    }
    @Published var sensitivity: Sensitivity {
        didSet { UserDefaults.standard.set(sensitivity.rawValue, forKey: "sensitivity") }
    }

    init() {
        let defaults = UserDefaults.standard
        style = WaveStyle(rawValue: defaults.string(forKey: "style") ?? "") ?? .aurora
        sensitivity = Sensitivity(rawValue: defaults.string(forKey: "sensitivity") ?? "") ?? .normal
    }

    // The last chosen audio source, so NotchWave picks up where you left it.
    var savedSource: AudioSource {
        get {
            let d = UserDefaults.standard
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
            let d = UserDefaults.standard
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let analyzer = SpectrumAnalyzer(bandCount: 24)
    private let settings = VisualizerSettings()
    private lazy var audio = AudioController(analyzer: analyzer)
    private lazy var notch = NotchWindowController(analyzer: analyzer, settings: settings)
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        analyzer.sensitivityDB = settings.sensitivity.gainDB
        notch.show()
        setUpStatusItem()

        audio.onError = { [weak self] error in
            self?.present(error)
        }
        audio.start(settings.savedSource)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        audio.stop()
    }

    @objc private func screensChanged() {
        notch.show()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "NotchWave")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt every time the menu opens, so the app list is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "NotchWave", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Source
        menu.addItem(sectionTitle("Listen to"))
        menu.addItem(sourceItem(.systemAudio, symbol: "speaker.wave.2"))
        menu.addItem(sourceItem(.microphone, symbol: "mic"))

        let appsItem = NSMenuItem(title: "Single App", action: nil, keyEquivalent: "")
        appsItem.image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil)
        let appsMenu = NSMenu()
        for app in runningApps() {
            guard let id = app.bundleIdentifier, let name = app.localizedName else { continue }
            let source = AudioSource.application(bundleID: id, name: name)
            let item = NSMenuItem(title: name, action: #selector(chooseSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = SourceBox(source)
            item.state = audio.source == source ? .on : .off
            if let icon = app.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            appsMenu.addItem(item)
        }
        if appsMenu.items.isEmpty {
            let none = NSMenuItem(title: "No apps running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            appsMenu.addItem(none)
        }
        appsItem.submenu = appsMenu
        if case .application = audio.source { appsItem.state = .on }
        menu.addItem(appsItem)

        menu.addItem(.separator())

        // Style
        menu.addItem(sectionTitle("Style"))
        for style in WaveStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = settings.style == style ? .on : .off
            menu.addItem(item)
        }

        let sensItem = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
        let sensMenu = NSMenu()
        for level in Sensitivity.allCases {
            let item = NSMenuItem(title: level.title, action: #selector(chooseSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = level.rawValue
            item.state = settings.sensitivity == level ? .on : .off
            sensMenu.addItem(item)
        }
        sensItem.submenu = sensMenu
        menu.addItem(sensItem)

        menu.addItem(.separator())
        let pause = NSMenuItem(title: audio.source == nil ? "Resume Listening" : "Pause Listening",
                               action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        menu.addItem(pause)

        let quit = NSMenuItem(title: "Quit NotchWave", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func sectionTitle(_ title: String) -> NSMenuItem {
        NSMenuItem.sectionHeader(title: title)
    }

    private func sourceItem(_ source: AudioSource, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: source.title, action: #selector(chooseSource(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = SourceBox(source)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.state = audio.source == source ? .on : .off
        return item
    }

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    // MARK: - Actions

    @objc private func chooseSource(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SourceBox else { return }
        settings.savedSource = box.source
        audio.start(box.source)
    }

    @objc private func chooseStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = WaveStyle(rawValue: raw) else { return }
        settings.style = style
    }

    @objc private func chooseSensitivity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let level = Sensitivity(rawValue: raw) else { return }
        settings.sensitivity = level
        analyzer.sensitivityDB = level.gainDB
    }

    @objc private func togglePause() {
        if audio.source == nil {
            audio.start(settings.savedSource)
        } else {
            audio.stop()
            analyzer.reset()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Errors

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "NotchWave can’t listen right now"
        alert.informativeText = error.localizedDescription
        let settingsURL = (error as? CaptureError)?.settingsURL
        if settingsURL != nil {
            alert.addButton(withTitle: "Open System Settings")
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let url = settingsURL {
            NSWorkspace.shared.open(url)
        }
    }
}

/// NSMenuItem.representedObject needs an object; this wraps the enum.
private final class SourceBox: NSObject {
    let source: AudioSource
    init(_ source: AudioSource) { self.source = source }
}
