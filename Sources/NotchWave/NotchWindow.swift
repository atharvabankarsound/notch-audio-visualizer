import AppKit
import SwiftUI

/// Size of the notch on a given screen, read from the system rather than hard-coded,
/// so it fits every notched MacBook (14", 15", 16", Air and Pro).
struct NotchGeometry {
    let notchSize: CGSize
    let hasNotch: Bool

    /// The built-in notched display if there is one, otherwise the main screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    static func detect(on screen: NSScreen) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        if top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // The notch is whatever sits between the two usable menu bar areas.
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(notchSize: CGSize(width: width, height: top), hasNotch: true)
        }
        // No notch (external display or older Mac): draw a virtual one, menu-bar tall,
        // that only appears while audio is playing — like a Dynamic Island.
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return NotchGeometry(notchSize: CGSize(width: 180, height: menuBarHeight), hasNotch: false)
    }
}

/// Fixed design constants for the area around the notch (in points).
enum NotchLayout {
    static let maxWing: CGFloat = 112      // how far the black shape grows out of each side
    static let maxDrop: CGFloat = 10       // how far it grows below the notch
    static let ear: CGFloat = 6            // concave flare where the shape meets the screen edge
    static let padding: CGFloat = 4
}

/// A borderless, click-through panel pinned over the notch, above the menu bar.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// By default macOS pushes windows below the menu bar. We need to sit in it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class NotchWindowController {
    private let analyzer: SpectrumAnalyzer
    private let settings: VisualizerSettings
    private var panel: NotchPanel?

    init(analyzer: SpectrumAnalyzer, settings: VisualizerSettings) {
        self.analyzer = analyzer
        self.settings = settings
    }

    /// Creates (or re-creates, after a display change) the overlay.
    func show() {
        panel?.orderOut(nil)
        panel = nil

        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry.detect(on: screen)

        let width = geometry.notchSize.width
            + 2 * (NotchLayout.maxWing + NotchLayout.ear + NotchLayout.padding)
        let height = geometry.notchSize.height + NotchLayout.maxDrop + NotchLayout.padding
        let frame = NSRect(x: screen.frame.midX - width / 2,
                           y: screen.frame.maxY - height,
                           width: width,
                           height: height)

        let panel = NotchPanel(contentRect: frame)
        let root = NotchVisualizerView(analyzer: analyzer,
                                       geometry: geometry,
                                       settings: settings)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}
