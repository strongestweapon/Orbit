import SwiftUI
import AppKit

final class OrbitAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: OrbitModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.shutdownForTermination()
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdownForTermination() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Refresh the running Dock tile directly; Launch Services can retain the old
        // generic icon when an Xcode build replaces an existing app bundle in place.
        guard let url = Bundle.main.url(forResource: "OrbitAppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}

/// The operator window owns the session. Its close button also closes the separately owned output Space.
struct OperatorWindowLifecycle: NSViewRepresentable {
    let model: OrbitModel
    func makeNSView(context: Context) -> OperatorLifecycleView { OperatorLifecycleView(model:model) }
    func updateNSView(_ view: OperatorLifecycleView, context: Context) {}
}

final class OperatorLifecycleView: NSView {
    private weak var model: OrbitModel?
    private var closeObserver: NSObjectProtocol?
    init(model: OrbitModel) { self.model=model;super.init(frame:.zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver);self.closeObserver=nil }
        guard let window else { return }
        window.identifier=NSUserInterfaceItemIdentifier("orbitOperator")
        closeObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in
            self?.model?.shutdownForTermination()
            // Finish the native close notification before terminating the application.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
}

@main
struct OrbitApplication: App {
    @NSApplicationDelegateAdaptor(OrbitAppDelegate.self) private var appDelegate
    @StateObject private var model = OrbitModel()
    @StateObject private var updater = OrbitUpdater()
    var body: some Scene {
        Window("Orbit",id:"operator") {
            ContentView(model: model)
                .background(OperatorWindowLifecycle(model:model).frame(width:0,height:0))
                .environmentObject(updater)
                .disabled(updater.installing)
                .frame(minWidth: 1060, minHeight: 700)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.model = model
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    model.restoreSessionOnce()
                    updater.startOnce(model: model)
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck || updater.isBlocked || updater.installing)
            }
            CommandGroup(after: .newItem) {
                Button("재생 / 일시정지") { model.playing.toggle() }.keyboardShortcut(.space, modifiers: [])
                Button("출력 전체화면 전환") { model.toggleOutputFullscreen() }
                    .keyboardShortcut("f", modifiers: [.command,.shift]).disabled(!model.outputOpen)
                Button("출력 중지") { model.stopOutput() }.keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}
