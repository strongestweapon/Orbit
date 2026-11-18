import Foundation

/// Serializes installation on the main queue and rechecks live output after
/// transitions such as startOutput(), which briefly closes the previous window.
@MainActor
final class UpdateInstallationGate {
    private let isBlocked: () -> Bool
    private let prepare: () -> Void
    private let enqueue: (@escaping () -> Void) -> Void
    private var pending: (() -> Void)?
    private var scheduled = false
    private var generation = 0

    var hasPendingInstallation: Bool { pending != nil }

    init(isBlocked: @escaping () -> Bool, prepare: @escaping () -> Void,
         enqueue: @escaping (@escaping () -> Void) -> Void = { action in DispatchQueue.main.async { action() } }) {
        self.isBlocked = isBlocked; self.prepare = prepare; self.enqueue = enqueue
    }

    func schedule(_ installation: @escaping () -> Void) {
        pending = installation
        resumeIfSafe()
    }

    func resumeIfSafe() {
        guard pending != nil, !scheduled, !isBlocked() else { return }
        scheduled = true
        let token = generation
        enqueue { [weak self] in
            guard let self, self.generation == token else { return }
            self.scheduled = false
            guard !self.isBlocked(), let installation = self.pending else { return }
            self.pending = nil
            self.prepare()
            installation()
        }
    }

    func cancel() {
        generation += 1
        pending = nil
        scheduled = false
    }
}
