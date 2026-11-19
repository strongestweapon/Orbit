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
        drain()
        precondition(events.isEmpty && gate.hasPendingInstallation, "A ready update must wait for user consent even while idle")
        gate.installAfterUserConfirmation()
        precondition(events.isEmpty, "Installation must not run inside the confirmation callback")
        // Starting output after the update is ready must still protect playback.
        output = true
        drain()
        precondition(events.isEmpty && gate.hasPendingInstallation)
        output = false; control = true
        gate.installAfterUserConfirmation(); drain()
        precondition(events.isEmpty, "Ableton control output must also prevent restart")
        control = false; benchmark = true
        gate.installAfterUserConfirmation(); drain()
        precondition(events.isEmpty, "A GPU benchmark must not be interrupted")
        benchmark = false
        drain()
        precondition(events.isEmpty, "Ending output/control/benchmark must never auto-resume installation")
        gate.installAfterUserConfirmation(); gate.installAfterUserConfirmation()
        drain()
        precondition(events == ["save", "install"] && !gate.hasPendingInstallation)
        gate.installAfterUserConfirmation(); drain()
        precondition(events.count == 2, "The installation callback must only run once")

        events = []
        gate.schedule { events.append("cancelled-install") }
        gate.installAfterUserConfirmation()
        gate.cancel()
        gate.schedule { events.append("new-install") }
        drain()
        precondition(events.isEmpty, "Consent from a cancelled cycle must not authorize another update")
        gate.installAfterUserConfirmation()
        drain()
        precondition(events == ["save", "new-install"], "A cancelled cycle must not consume a later installation")

        events = []
        output = true
        gate.schedule { events.append("after-output-switch") }
        output = false; gate.installAfterUserConfirmation()
        output = true // Replacing an output window briefly sets outputOpen to false.
        drain()
        precondition(events.isEmpty)
        output = false; drain()
        precondition(events.isEmpty, "A blocked confirmation is consumed; a fresh choice is required")
        gate.installAfterUserConfirmation(); drain()
        precondition(events == ["save", "after-output-switch"])
        print("PASS: explicit consent, no idle auto-restart, output/control/benchmark deferral, fresh consent after races, cancellation, save-before-restart, exactly-once installation")
    }
}
