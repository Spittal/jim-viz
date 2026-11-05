import AppKit
import Metal
import Observation

/// An NSView backed by a render surface. Registers itself with the render loop and
/// reports whether it is actually visible so hidden views cost nothing.
final class MetalSurfaceView: NSView {
    let surface: RenderSurface
    private weak var loop: RenderLoop?
    private var occlusionObserver: NSObjectProtocol?
    var hidesCursor = false

    /// Set when this view shows a video texture rather than the rendered output.
    private var preview: VideoPreview?

    init(device: MTLDevice, loop: RenderLoop) {
        surface = RenderSurface(device: device)
        self.loop = loop
        super.init(frame: .zero)
        wantsLayer = true
        loop.add(surface)
    }

    /// A view showing a video texture, such as a webcam's processed output.
    init(device: MTLDevice, loop: RenderLoop, video: @escaping () -> MTLTexture?) {
        let p = VideoPreview(device: device, source: video)
        preview = p
        surface = p.layer
        self.loop = loop
        super.init(frame: .zero)
        wantsLayer = true
        loop.add(p)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let preview { loop?.remove(preview) } else { loop?.remove(surface) }
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
    }

    override func makeBackingLayer() -> CALayer { surface.layer }

    override func layout() {
        super.layout()
        updateSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.updateVisibility() }
        }
        updateSize()
    }

    override func viewDidHide() { super.viewDidHide(); updateVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateVisibility() }

    override func resetCursorRects() {
        if hidesCursor {
            addCursorRect(bounds, cursor: NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero))
        }
    }

    private func updateSize() {
        let scale = window?.backingScaleFactor ?? 2
        surface.layer.contentsScale = scale
        let size = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
        if surface.layer.drawableSize != size { surface.layer.drawableSize = size }
        updateVisibility()
    }

    private func updateVisibility() {
        guard let window else { surface.visible = false; return }
        surface.visible = window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
            && bounds.width > 1 && bounds.height > 1
    }
}

struct ScreenInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let pixelSize: CGSize
    let isMain: Bool
}

/// Manages the projector output: off, a normal window for testing, or borderless fullscreen
/// on a chosen display. If the projector disconnects, output drops to a window and returns
/// to fullscreen automatically when it reconnects.
@Observable
final class OutputController: NSObject, NSWindowDelegate {
    enum Mode: Equatable {
        case off
        case windowed
        case fullscreen(CGDirectDisplayID)
    }

    private(set) var mode: Mode = .off
    private(set) var screens: [ScreenInfo] = []

    @ObservationIgnored private let device: MTLDevice
    @ObservationIgnored private let loop: RenderLoop
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var waitingForDisplay: CGDirectDisplayID?

    init(device: MTLDevice, loop: RenderLoop) {
        self.device = device
        self.loop = loop
        super.init()
    }

    func start() {
        refreshScreens()
        followScreen()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
    }

    var modeLabel: String {
        switch mode {
        case .off: return "Output Off"
        case .windowed: return "Windowed"
        case .fullscreen(let id): return screens.first { $0.id == id }?.name ?? "Fullscreen"
        }
    }

    /// The best display for the projector: the first non-main screen, or the main screen.
    var preferredScreen: ScreenInfo? {
        screens.first { !$0.isMain } ?? screens.first
    }

    func toggleFullscreen() {
        if case .fullscreen = mode {
            setMode(.off)
        } else if let s = preferredScreen {
            setMode(.fullscreen(s.id))
        }
    }

    func setMode(_ newMode: Mode) {
        waitingForDisplay = nil
        apply(newMode)
    }

    private func apply(_ newMode: Mode) {
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        mode = newMode

        switch newMode {
        case .off:
            break
        case .windowed:
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "jim-viz Output"
            w.contentAspectRatio = NSSize(width: 16, height: 9)
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            w.contentView = MetalSurfaceView(device: device, loop: loop)
            w.center()
            w.delegate = self
            w.makeKeyAndOrderFront(nil)
            window = w
        case .fullscreen(let id):
            guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) else {
                mode = .off
                return
            }
            let w = OutputWindow(contentRect: screen.frame, styleMask: [.borderless],
                                 backing: .buffered, defer: false, screen: screen)
            w.onEscape = { [weak self] in self?.setMode(.off) }
            w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            w.hidesOnDeactivate = false
            let view = MetalSurfaceView(device: device, loop: loop)
            view.hidesCursor = true
            w.contentView = view
            w.setFrame(screen.frame, display: true)
            w.delegate = self
            // Don't steal key focus from the control window.
            w.orderFrontRegardless()
            window = w
        }
        followScreen()
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === window {
            window = nil
            waitingForDisplay = nil
            mode = .off
            followScreen()
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        followScreen()
    }

    /// Pace rendering to the output's display so the projector gets clean frames.
    private func followScreen() {
        if let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first {
            loop.follow(screen: screen)
        }
    }

    private func refreshScreens() {
        let main = NSScreen.screens.first?.displayID
        screens = NSScreen.screens.map { s in
            let scale = s.backingScaleFactor
            return ScreenInfo(id: s.displayID, name: s.localizedName,
                              pixelSize: CGSize(width: s.frame.width * scale, height: s.frame.height * scale),
                              isMain: s.displayID == main)
        }
    }

    private func screensChanged() {
        refreshScreens()
        if case .fullscreen(let id) = mode {
            if let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
                window?.setFrame(screen.frame, display: true)
            } else {
                // Projector disconnected: keep visuals running in a window and wait for it.
                apply(.windowed)
                waitingForDisplay = id
            }
        } else if let id = waitingForDisplay, screens.contains(where: { $0.id == id }) {
            waitingForDisplay = nil
            apply(.fullscreen(id))
        }
        followScreen()
    }
}

final class OutputWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
