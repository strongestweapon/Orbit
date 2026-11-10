import SwiftUI
import AppKit

final class OrbitAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Refresh the running Dock tile directly; Launch Services can retain the old
        // generic icon when an Xcode build replaces an existing app bundle in place.
        guard let url = Bundle.main.url(forResource: "OrbitAppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}

@main
struct OrbitApplication: App {
    @NSApplicationDelegateAdaptor(OrbitAppDelegate.self) private var appDelegate
    @StateObject private var model = OrbitModel()
    var body: some Scene {
        WindowGroup("Orbit") {
            ContentView(model: model)
                .frame(minWidth: 1060, minHeight: 700)
                .preferredColorScheme(.dark)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("재생 / 일시정지") { model.playing.toggle() }.keyboardShortcut(.space, modifiers: [])
                Button("출력 전체화면 전환") { model.toggleOutputFullscreen() }
                    .keyboardShortcut("f", modifiers: [.command,.shift]).disabled(!model.outputOpen)
                Button("출력 중지") { model.stopOutput() }.keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}
