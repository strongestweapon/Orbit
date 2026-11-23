import Foundation

/// Small, stateful angular simulation shared by every preview and the LED output.
/// Gravity here is an artistic attraction to an angle, not a central gravity model.
struct PulseOrbitSimulation {
    static let sceneID = "09_pulse_orbit"
    static let particleCount = 12
    static let uniformCount = 56
    private(set) var positions: [Double] = (0..<12).map { (index: Int) -> Double in
        let lane = Double(index / 4) * 0.117
        let slot = Double(index % 4) * 0.25
        return (0.08 + lane + slot).truncatingRemainder(dividingBy: 1)
    }
    private(set) var velocities = [Double](repeating: 0, count: 12)
    private(set) var time = 0.0
    private var remainder = 0.0

    struct Controls {
        var drive: Double
        var attraction: Double
        var inertia: Double
        var center: Double
        var dynamics: Double
        var rhythmRate: Double
        var counterflow: Bool
        init(drive: Double, attraction: Double, inertia: Double, center: Double,
             dynamics: Double = 0.85, rhythmRate: Double = 0.55, counterflow: Bool = true) {
            func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
            self.drive = unit(drive); self.attraction = unit(attraction)
            self.inertia = unit(inertia); self.center = unit(center)
            self.dynamics = unit(dynamics); self.rhythmRate = unit(rhythmRate); self.counterflow = counterflow
        }
        init(uniforms: [Float]) {
            self.init(drive: Double(uniforms[4]), attraction: Double(uniforms[5]),
                      inertia: Double(uniforms[6]), center: Double(uniforms[20]),
                      dynamics: uniforms.count > 52 ? Double(uniforms[52]) : 0.85,
                      rhythmRate: uniforms.count > 53 ? Double(uniforms[53]) : 0.55,
                      counterflow: uniforms.count > 55 ? uniforms[55] >= 0.5 : true)
        }
    }

    init() {}
    init(uniforms: [Float]) {
        if uniforms.count >= 48 {
            positions = uniforms[24..<36].map(Double.init)
            velocities = uniforms[36..<48].map(Double.init)
        }
        if uniforms.count > 51 { time = Double(uniforms[51]) }
    }
    var uniforms: [Float] { positions.map(Float.init) + velocities.map(Float.init) }

    mutating func advance(by elapsed: Double, controls: Controls) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        // Bound catch-up after sleep/minimization; fixed substeps keep behavior independent of FPS.
        remainder += min(elapsed, 0.25)
        let step = 1.0 / 120.0
        let count = Int((remainder + 1e-10) / step)
        remainder = max(0, remainder - Double(count) * step)
        let mass = 0.18 + controls.inertia * 1.6
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(1, max(0, (x-a)/(b-a))); return t*t*(3-2*t)
        }
        for _ in 0..<count {
            time += step
            for index in positions.indices {
                let lane = index / 4
                let slot = index % 4
                let laneSpeed = [0.86, 1.0, 1.14][lane]
                // Offset bursts let packets catch up and separate. Keep this phase
                // formula in sync with the Metal emitter envelope.
                let period = (10 - controls.rhythmRate * 7) * (1 + Double(lane)*0.09 + Double(slot)*0.13)
                let phase = (time/period + Double(lane)*0.19 + Double(slot)*0.27).truncatingRemainder(dividingBy:1)
                let burst = smooth(0.02,0.08,phase) * (1-smooth(0.30,0.74,phase))
                let surge = 1 + controls.dynamics * (0.2 + burst*2.8 - 1)
                let direction = controls.counterflow && lane == 1 ? -1.0 : 1.0
                let drive = (controls.drive * 2 - 1) * 0.16 * laneSpeed * surge * direction
                let pull = -controls.attraction * 0.45 * sin((positions[index] - controls.center) * 2 * .pi)
                velocities[index] += (drive + pull - velocities[index]) / mass * step
                positions[index] += velocities[index] * step
                positions[index] -= floor(positions[index])
            }
        }
    }
}
