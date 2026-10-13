import AppKit
import SwiftUI

// MARK: - Where the notch is

/// The notch's rectangle in global screen coordinates (origin bottom-left), or a stand-in on a
/// screen without one.
struct NotchMetrics: Equatable {
    var screenFrame: CGRect
    var rect: CGRect
    var hasHardwareNotch: Bool

    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }

    /// Size of the drawn notch on a Mac without one.
    static let fakeSize = CGSize(width: 190, height: 32)

    /// Prefers the screen that has a notch; otherwise the screen holding the menu bar.
    @MainActor
    static func current() -> (NSScreen?, NotchMetrics) {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? screens.first else {
            let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
            return (nil, fake(in: frame, menuBarHeight: 0))
        }
        return (screen, metrics(for: screen))
    }

    @MainActor
    static func metrics(for screen: NSScreen) -> NotchMetrics {
        let frame = screen.frame
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // The two auxiliary areas are the menu bar strips either side of the notch. Using only
            // their widths keeps this right whether AppKit reports them screen-local or global.
            let width = frame.width - left.width - right.width
            if width > 0 {
                let rect = CGRect(x: frame.minX + left.width, y: frame.maxY - top, width: width, height: top)
                return NotchMetrics(screenFrame: frame, rect: rect, hasHardwareNotch: true)
            }
        }
        return fake(in: frame, menuBarHeight: frame.maxY - screen.visibleFrame.maxY)
    }

    private static func fake(in frame: CGRect, menuBarHeight: CGFloat) -> NotchMetrics {
        // With an auto-hiding menu bar the reserved height is 0; draw at the usual size anyway.
        let height = menuBarHeight >= 20 ? menuBarHeight : fakeSize.height
        let rect = CGRect(x: frame.midX - fakeSize.width / 2, y: frame.maxY - height,
                          width: fakeSize.width, height: height)
        return NotchMetrics(screenFrame: frame, rect: rect, hasHardwareNotch: false)
    }
}

// MARK: - The window

/// Borderless, transparent, never takes focus, sits above the menu bar on every Space and over
/// full-screen apps.
final class IslandPanel: NSPanel {
    /// Above the menu bar (24) and its status items (25). In full screen the menu bar is hidden,
    /// and .fullScreenAuxiliary is what lets the panel into that Space at all.
    static let islandLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = Self.islandLevel   // after isFloatingPanel, which resets the level to .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false           // the island draws its own soft shadow
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        // ignoresMouseEvents is deliberately never assigned. Setting it, even to false, turns off
        // the window server's pass-through of clicks on fully transparent pixels, and this
        // window's margin must stay fully transparent: no shadow here (see ShadowPanel).
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit pushes ordinary windows below the menu bar. This one belongs on top of it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Draws only the island's soft shadow, just below the island window. It ignores the mouse
/// entirely: a shadow is never fully transparent, and in the island window it would catch
/// clicks meant for menu bar items and app content around the island.
final class ShadowPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = IslandPanel.islandLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The panel's content view. Owns the tracking area that turns "mouse over the island" into
/// hover events, so the menu bar never has to be watched.
final class IslandContainerView: NSView {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}

    /// The island's current target rectangle, in this view's coordinates.
    var hotRect: CGRect = .zero {
        didSet { if hotRect != oldValue { rebuildTrackingArea() } }
    }
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingArea()
    }

    private func rebuildTrackingArea() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        guard !hotRect.isEmpty else { trackingArea = nil; return }
        // .activeAlways: this app is never active, and tracking areas are otherwise ignored.
        let area = NSTrackingArea(rect: hotRect, options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panel is never key, so without this the first click on a button would only "focus" the
/// window and the button would need a second click.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
