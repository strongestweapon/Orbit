import SwiftUI
import AppKit

@main
struct OrbitApplication: App {
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
                Button("출력 중지") { model.stopOutput() }.keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}
