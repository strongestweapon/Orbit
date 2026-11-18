import Foundation

@main
struct UpdateInstallationChecks {
    @MainActor static func main() {
        var output = false, control = false, benchmark = false
        var queue: [() -> Void] = []
        var events: [String] = []
        let gate = UpdateInstallationGate(
            isBlocked: { output || control || benchmark },
            prepare: { events.append("save") },
            enqueue: { queue.append($0) })
        func drain() { while !queue.isEmpty { queue.removeFirst()() } }

        gate.schedule { events.append("install") }
        precondition(events.isEmpty, "Installation must not run inside a Sparkle delegate callback")
        // Starting output after the update is ready must still protect playback.
        output = true
        drain()
        precondition(events.isEmpty && gate.hasPendingInstallation)
        output = false; control = true
        gate.resumeIfSafe(); drain()
        precondition(events.isEmpty, "Ableton control output must also prevent restart")
        control = false; benchmark = true
        gate.resumeIfSafe(); drain()
        precondition(events.isEmpty, "A GPU benchmark must not be interrupted")
        benchmark = false
        gate.resumeIfSafe(); gate.resumeIfSafe()
        drain()
        precondition(events == ["save", "install"] && !gate.hasPendingInstallation)
        gate.resumeIfSafe(); drain()
        precondition(events.count == 2, "The installation callback must only run once")

        events = []
        gate.schedule { events.append("cancelled-install") }
        gate.cancel()
        gate.schedule { events.append("new-install") }
        drain()
        precondition(events == ["save", "new-install"], "A cancelled cycle must not consume a later installation")

        events = []
        output = true
        gate.schedule { events.append("after-output-switch") }
        output = false; gate.resumeIfSafe()
        output = true // Replacing an output window briefly sets outputOpen to false.
        drain()
        precondition(events.isEmpty)
        output = false; gate.resumeIfSafe(); drain()
        precondition(events == ["save", "after-output-switch"])
        print("PASS: output/control/benchmark deferral, transition race, cancellation, save-before-restart, exactly-once installation")
    }
}
