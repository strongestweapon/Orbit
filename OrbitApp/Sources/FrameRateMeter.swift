import Foundation

/// Uses GPU completion timestamps rather than the arrival time of main-thread callbacks.
struct FrameRateMeter {
    private var times: [TimeInterval] = []
    mutating func reset() { times.removeAll(keepingCapacity:true) }

    mutating func record(completedAt time: TimeInterval) {
        guard time.isFinite, time > 0 else { return }
        if let last = times.last {
            guard time > last else { return }
            if time-last >= 1 { reset() }
        }
        times.append(time)
        // Retain the interval crossing the beginning of the last second.
        while times.count > 2 && times[1] < time-1 { times.removeFirst() }
    }

    func framesPerSecond(at now: TimeInterval) -> Double? {
        guard now.isFinite, let first=times.first, let last=times.last else { return nil }
        if now-last >= 1 { return 0 }
        let elapsed=last-first
        guard elapsed >= 0.25 else { return nil }
        return Double(times.count-1)/elapsed
    }
}
