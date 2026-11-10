import AppKit

/// Black letterbox area surrounds a 16:9 Metal view in both windowed and fullscreen modes.
final class OrbitOutputContentView: NSView {
    let metalView: OrbitMTKView
    var resolution: OutputResolution
    var customWidth: Int
    var geometryChanged: ((CGSize) -> Void)?
    private(set) var renderSize: CGSize = .zero

    init(model: OrbitModel, sessionID: UUID, resolution: OutputResolution, customWidth: Int) {
        self.resolution = resolution; self.customWidth = customWidth
        metalView = OrbitMetalView.make(model: model, mode: 2, isOutput: true, outputSession: sessionID)
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        metalView.autoResizeDrawable = false
        addSubview(metalView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); updateGeometry() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateGeometry() }
    func updateGeometry() {
        let fitted = OutputGeometry.fittedRect(in: bounds)
        guard fitted.width > 0, fitted.height > 0 else { return }
        metalView.frame = fitted
        let pixels = convertToBacking(fitted).size
        let size = resolution.size(availablePixels: pixels, customWidth: customWidth)
        guard size.width > 0, size.height > 0 else { return }
        if metalView.drawableSize != size { metalView.drawableSize = size }
        if renderSize != size { renderSize = size; geometryChanged?(size) }
    }
    func stopRendering() {
        metalView.isPaused = true; metalView.delegate = nil; metalView.renderer = nil
    }
}

final class OrbitOutputWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        if styleMask.contains(.fullScreen) { toggleFullScreen(sender) }
        else { super.cancelOperation(sender) }
    }
}

final class OrbitOutputWindowController: NSWindowController, NSWindowDelegate {
    let sessionID = UUID()
    private(set) var outputView: OrbitOutputContentView!
    var closed: (() -> Void)?
    var changed: ((Bool, String, CGSize) -> Void)?

    init(model: OrbitModel, screen: NSScreen, resolution: OutputResolution, customWidth: Int) {
        let available = screen.visibleFrame
        let initial = OutputGeometry.fittedRect(in: CGRect(x: 0, y: 0,
            width: min(960, available.width*0.78), height: min(540, available.height*0.72)))
        let window = OrbitOutputWindow(contentRect: initial, styleMask: [.titled,.closable,.miniaturizable,.resizable],
                                      backing: .buffered, defer: false, screen: screen)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.title = "Orbit 출력"
        window.backgroundColor = .black
        // Keep the live output above the operator window even when its controls have focus.
        window.level = .floating
        window.contentMinSize = CGSize(width: 320, height: 180)
        window.contentAspectRatio = CGSize(width: 16, height: 9)
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        outputView = OrbitOutputContentView(model: model, sessionID: sessionID,
                                           resolution: resolution, customWidth: customWidth)
        outputView.autoresizingMask = [.width,.height]
        outputView.geometryChanged = { [weak self] _ in self?.reportState() }
        window.contentView = outputView
        window.setFrameOrigin(NSPoint(x: available.midX-window.frame.width/2,
                                      y: available.midY-window.frame.height/2))
        let accessory = NSTitlebarAccessoryViewController()
        let button = NSButton(title: "전체화면", target: self, action: #selector(toggleFullscreen))
        button.bezelStyle = .rounded
        button.frame = CGRect(x: 0, y: 0, width: 92, height: 24)
        button.setAccessibilityIdentifier("outputWindowFullscreen")
        accessory.view = button; accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func open() {
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        outputView.updateGeometry(); reportState()
    }
    func configure(resolution: OutputResolution, customWidth: Int) {
        outputView.resolution = resolution; outputView.customWidth = customWidth
        outputView.updateGeometry(); reportState()
    }
    @objc func toggleFullscreen(_ sender: Any? = nil) { window?.toggleFullScreen(sender) }
    func shutdown() {
        outputView.stopRendering(); window?.delegate = nil; window?.close()
    }
    private func reportState() {
        guard let window else { return }
        let size = outputView.renderSize
        window.title = "Orbit 출력 · \(OutputGeometry.label(size))"
        changed?(window.styleMask.contains(.fullScreen), window.screen?.localizedName ?? "현재 화면", size)
    }
    func windowWillClose(_ notification: Notification) { outputView.stopRendering(); closed?() }
    func windowWillEnterFullScreen(_ notification: Notification) { window?.level = .normal }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { window.level = .floating }
    func windowDidEnterFullScreen(_ notification: Notification) { outputView.updateGeometry(); reportState() }
    func windowDidExitFullScreen(_ notification: Notification) {
        window?.level = .floating
        outputView.updateGeometry(); reportState()
    }
    func windowDidChangeScreen(_ notification: Notification) { outputView.updateGeometry(); reportState() }
    func windowDidChangeBackingProperties(_ notification: Notification) { outputView.updateGeometry(); reportState() }
}
