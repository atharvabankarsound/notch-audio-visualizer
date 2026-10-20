import AppKit

/// Entry point. NotchWave runs as a menu bar "accessory" app:
/// no Dock icon, no main window — just the notch overlay and a menu bar icon.
@main
enum NotchWaveMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
