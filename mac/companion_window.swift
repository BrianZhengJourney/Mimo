import Cocoa

// The window the companion lives in.
//
// One transparent, borderless, always-on-top panel per display, covering the
// full screen frame — not `visibleFrame`, so a companion can walk over the menu
// bar region rather than hitting an invisible wall partway up.
//
// All companions composite inside this one layer tree. Shimeji gives every
// mascot its own OS window, which means the compositor manages one translucent
// always-on-top window per mascot and resizes each every frame; at its own
// 50-mascot cap that is 50 windows. See docs/companion/01-shimeji-research.md §1.9.
//
// Click-through is the delicate part. A full-screen window that accepts mouse
// events would swallow every click on the desktop, so `ignoresMouseEvents`
// stays true and is lifted only while the cursor is genuinely over companion
// artwork. The runtime re-evaluates that each frame against the baked alpha
// mask — replacing the 10Hz poll of a hardcoded rectangle in main.swift.

final class CompanionLayerWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    let hostView: CompanionHostView

    init(screen: NSScreen) {
        hostView = CompanionHostView(frame: CGRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        // She lives on the desktop, not on top of your work: one notch above
        // the desktop icons, below every normal window, so apps occlude her
        // exactly like anything else lying on the desktop. The old float-over-
        // everything behaviour remains behind a default for anyone who wants
        // a companion that sits on their windows:
        //   defaults write com.brianzheng.mimo companionAboveWindows -bool true
        if UserDefaults.standard.bool(forKey: "companionAboveWindows") {
            level = .statusBar
        } else {
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        contentView = hostView
        setFrame(screen.frame, display: false)
        orderFrontRegardless()
    }

    /// Follows the display through resolution and arrangement changes.
    func syncFrame(to screen: NSScreen) {
        guard frame != screen.frame else { return }
        setFrame(screen.frame, display: false)
        hostView.frame = CGRect(origin: .zero, size: screen.frame.size)
        hostView.updateScale(screen.backingScaleFactor)
    }
}

/// Bare layer-backed view. Holds the companion layers and forwards mouse events.
final class CompanionHostView: NSView {
    /// Called on mouse-down inside companion artwork, in screen coordinates.
    var onMouseDown: ((CGPoint) -> Void)?
    /// Called on right-click inside companion artwork.
    var onRightMouseDown: ((CGPoint) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = .clear
        // Positions come from the physics tick; implicit animation would fight
        // it and smear every frame into the next.
        layer?.actions = ["sublayers": NSNull(), "contents": NSNull(), "position": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    /// Per-display backing scale, so sprites stay crisp on mixed-DPI setups.
    /// The current implementation never reads backingScaleFactor at all.
    func updateScale(_ scale: CGFloat) {
        layer?.contentsScale = scale
        layer?.sublayers?.forEach { $0.contentsScale = scale }
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(NSEvent.mouseLocation)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightMouseDown?(NSEvent.mouseLocation)
    }

    /// The window only accepts events while the runtime has decided the cursor
    /// is over artwork, so anything that reaches us is ours to take.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
