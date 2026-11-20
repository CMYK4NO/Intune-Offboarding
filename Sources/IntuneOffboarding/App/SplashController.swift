import AppKit
import SwiftUI

/// Launch splash: an 800×450 borderless window centred on the visible area of the main screen (menu bar and
/// Dock excluded). The main window is kept hidden while it shows and is revealed only after it has gone.
@MainActor
final class SplashController {
    static let shared = SplashController()

    private static let size = NSSize(width: 800, height: 450)
    private static let duration: TimeInterval = 2.5
    private static let fadeDuration: TimeInterval = 0.3

    private var splash: NSWindow?
    private var heldWindows: [NSWindow] = []
    private var finished = false

    /// Called once at launch. Without the image the app simply opens normally.
    func show() {
        guard splash == nil, !finished else { return }
        guard let url = Bundle.main.url(forResource: "Splash", withExtension: "jpg"),
              let image = NSImage(contentsOf: url),
              let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            finish()
            return
        }
        let size = Self.size
        let frame = NSRect(x: (visible.midX - size.width / 2).rounded(),
                           y: (visible.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)

        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.ignoresMouseEvents = true

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently // the image is 16:9, like the window
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.masksToBounds = true
        imageView.setAccessibilityLabel("Device Offboarding")
        window.contentView = imageView

        window.orderFrontRegardless()
        splash = window
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
            self?.finish()
        }
    }

    /// Keeps a main window invisible until the splash is gone. Safe to call before or after `show()`.
    func hold(_ window: NSWindow) {
        guard !finished, window !== splash else { return }
        window.alphaValue = 0
        if !heldWindows.contains(where: { $0 === window }) { heldWindows.append(window) }
        // SwiftUI orders its window in after this point; hide it on the next turn so it cannot take clicks.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            window.orderOut(nil)
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        guard let splash else {
            reveal()
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            reveal()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            splash.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.reveal()
        })
    }

    /// Removes the splash first, then opens the tool.
    private func reveal() {
        splash?.orderOut(nil)
        splash = nil
        for window in heldWindows {
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
        }
        heldWindows = []
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Placed in the main window's content: hands that window to `SplashController` as soon as it exists.
struct SplashGate: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { GateView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class GateView: NSView {
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let newWindow { SplashController.shared.hold(newWindow) }
        }
    }
}
