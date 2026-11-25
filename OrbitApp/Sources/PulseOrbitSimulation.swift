import Foundation

/// Small, stateful angular simulation shared by every preview and the LED output.
/// Gravity here is an artistic attraction to an angle, not a central gravity model.
struct PulseOrbitSimulation {
    static let sceneID = "09_pulse_orbit"
    static let defaultLineCount = 3
    static let maximumLineCount = 10
    static let particleCount = 12
    // The original 56 floats stay stable; controls and crossing history follow.
    static let interactionOffset = 56
    static let eventOffset = 65
    static let pairCount = 16
    static let extendedOffset = 114
    static let extraParticleCapacity = (maximumLineCount-defaultLineCount)*4
    static let lineCountOffset = extendedOffset+extraParticleCapacity*2
    static let uniformCount = lineCountOffset+1
    var lineCount: Int { positions.count / 4 }
    private(set) var positions: [Double] = (0..<12).map { (index: Int) -> Double in
        let lane = Double(index / 4) * 0.117
        let slot = Double(index % 4) * 0.25
        return (0.08 + lane + slot).truncatingRemainder(dividingBy: 1)
    }
    private(set) var velocities = [Double](repeating: 0, count: 12)
    private(set) var time = 0.0
    private var remainder = 0.0
    private(set) var eventAngles = [Double](repeating: 0, count: pairCount)
    private(set) var eventTimes = [Double](repeating: -100, count: pairCount)
    private(set) var eventStrengths = [Double](repeating: 0, count: pairCount)
    struct Crossing { let angle: Double; let strength: Double; let time: Double }
    private var crossings: [Crossing] = []
    private(set) var proximity = 0.0
    mutating func takeCrossings() -> [Crossing] {
        let result = crossings; crossings.removeAll(keepingCapacity:true); return result
    }

    struct Controls {
        var drive: Double
        var attraction: Double
        var inertia: Double
        var center: Double
        var dynamics: Double
        var rhythmRate: Double
        var counterflow: Bool
        var clustering: Double
        var laneRates: [Double]
        var outerReverse: Bool
        var linkRange: Double
        var density: Double
        init(drive: Double, attraction: Double, inertia: Double, center: Double,
             dynamics: Double = 0.85, rhythmRate: Double = 0.55, counterflow: Bool = true,
             clustering: Double = 0.35, laneRates: [Double] = [1.0/3,1.0/3,1.0/3],
             outerReverse: Bool = true, linkRange: Double = 0.375, density: Double = 0.86) {
            func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
            self.drive = unit(drive); self.attraction = unit(attraction)
            self.inertia = unit(inertia); self.center = unit(center)
            self.dynamics = unit(dynamics); self.rhythmRate = unit(rhythmRate); self.counterflow = counterflow
            self.clustering = unit(clustering)
            self.laneRates = (0..<3).map { $0 < laneRates.count ? unit(laneRates[$0]) : 1.0/3 }
            self.outerReverse = outerReverse; self.linkRange = unit(linkRange); self.density = unit(density)
        }
        init(uniforms: [Float]) {
            self.init(drive: Double(uniforms[4]), attraction: Double(uniforms[5]),
                      inertia: Double(uniforms[6]), center: Double(uniforms[20]),
                      dynamics: uniforms.count > 52 ? Double(uniforms[52]) : 0.85,
                      rhythmRate: uniforms.count > 53 ? Double(uniforms[53]) : 0.55,
                      counterflow: uniforms.count > 55 ? uniforms[55] >= 0.5 : true,
                      clustering: uniforms.count > 64 ? Double(uniforms[56]) : 0.35,
                      laneRates: uniforms.count > 64 ? uniforms[57...59].map(Double.init) : [1.0/3,1.0/3,1.0/3],
                      outerReverse: uniforms.count > 64 ? uniforms[60] >= 0.5 : true,
                      linkRange: uniforms.count > 64 ? Double(uniforms[61]) : 0.375,
                      density: Double(uniforms[22]))
        }
    }

    init() {}
    init(uniforms: [Float]) {
        if uniforms.count >= 48 {
            positions = uniforms[24..<36].map(Double.init)
            velocities = uniforms[36..<48].map(Double.init)
        }
        if uniforms.count > 51 { time = Double(uniforms[51]) }
        if uniforms.count >= Self.extendedOffset {
            eventAngles = uniforms[65..<81].map(Double.init)
            eventTimes = uniforms[81..<97].map(Double.init)
            eventStrengths = uniforms[97..<113].map(Double.init)
            remainder = Double(uniforms[113])
        }
        if uniforms.count == Self.uniformCount {
            let count = uniforms[Self.lineCountOffset].isFinite ? Int(min(Float(Self.maximumLineCount),max(Float(Self.defaultLineCount),uniforms[Self.lineCountOffset]))) : Self.defaultLineCount
            let extra = (count-Self.defaultLineCount)*4
            positions += uniforms[Self.extendedOffset..<(Self.extendedOffset+extra)].map(Double.init)
            velocities += uniforms[(Self.extendedOffset+Self.extraParticleCapacity)..<(Self.extendedOffset+Self.extraParticleCapacity+extra)].map(Double.init)
        }
    }
    var uniforms: [Float] { positions.prefix(12).map(Float.init) + velocities.prefix(12).map(Float.init) }
    var extendedUniforms: [Float] {
        let extra = (lineCount-Self.defaultLineCount)*4
        let padding = [Float](repeating:0,count:Self.extraParticleCapacity-extra)
        return positions.dropFirst(12).map(Float.init)+padding+velocities.dropFirst(12).map(Float.init)+padding+[Float(lineCount)]
    }
    /// A persistent live command, not an envelope applied to the density slider.
    mutating func addLine(limit: Int = maximumLineCount) {
        let ceiling = min(Self.maximumLineCount,max(Self.defaultLineCount+1,limit))
        setLineCount(lineCount >= ceiling ? Self.defaultLineCount : lineCount+1)
    }
    mutating func setLineCount(_ requested: Int) {
        let target = min(Self.maximumLineCount,max(Self.defaultLineCount,requested))*4
        guard target != positions.count else {return}
        if target > positions.count {
            for index in positions.count..<target {
                let phase = 0.08 + Double(index/4)*0.117 + Double(index%4)*0.25 + time*0.037
                positions.append(phase-floor(phase)); velocities.append(0)
            }
        } else {positions=Array(positions.prefix(target));velocities=Array(velocities.prefix(target))}
        // The outer lane changed; old pair history must not create phantom cues.
        crossings.removeAll();proximity=0
        eventTimes=[Double](repeating:-100,count:Self.pairCount)
        eventStrengths=[Double](repeating:0,count:Self.pairCount)
    }
    var eventUniforms: [Float] { eventAngles.map(Float.init) + eventTimes.map(Float.init) + eventStrengths.map(Float.init) + [Float(remainder)] }

    func writeState(to packed: inout [Float]) {
        precondition(packed.count == Self.uniformCount)
        packed.replaceSubrange(24..<48, with: uniforms)
        packed[51] = Float(time)
        packed.replaceSubrange(Self.eventOffset..<Self.extendedOffset, with: eventUniforms)
        packed.replaceSubrange(Self.extendedOffset..<Self.uniformCount, with: extendedUniforms)
    }

    static func wrapped(_ turns: Double) -> Double { turns - floor(turns + 0.5) }
    /// A jump across the antipode is not an alignment; crossing the U=0 seam is.
    static func crossed(from previous: Double, to current: Double, threshold: Double) -> Bool {
        previous != 0 && previous * current <= 0 && abs(previous-current) < 0.5
            && abs(previous) < threshold && abs(current) < threshold
    }

    mutating func advance(by elapsed: Double, controls: Controls) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        // Bound catch-up after sleep/minimization; fixed substeps keep behavior independent of FPS.
        crossings.removeAll(keepingCapacity:true) // Emissions belong to this advance call only.
        remainder += min(elapsed, 0.25)
        let step = 1.0 / 120.0
        let count = Int((remainder + 1e-10) / step)
        remainder = max(0, remainder - Double(count) * step)
        let mass = 0.18 + controls.inertia * 1.6
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(1, max(0, (x-a)/(b-a))); return t*t*(3-2*t)
        }
        for _ in 0..<count {
            let previous = positions
            time += step
            for index in positions.indices {
                let lane = index / 4
                let slot = index % 4
                let role = lane == 0 ? 0 : (lane == lineCount-1 ? 2 : 1)
                let laneSpeed = 0.86 + 0.28*Double(lane)/Double(lineCount-1)
                let rate = controls.laneRates[role] * 3
                if rate == 0 { velocities[index] = 0; continue }
                // Offset bursts let packets catch up and separate. Keep this phase
                // formula in sync with the Metal emitter envelope.
                let period = (10 - controls.rhythmRate * 7) * (1 + Double(lane)*0.09 + Double(slot)*0.13)
                let phase = (time/period + Double(lane)*0.19 + Double(slot)*0.27).truncatingRemainder(dividingBy:1)
                let burst = smooth(0.02,0.08,phase) * (1-smooth(0.30,0.74,phase))
                let surge = 1 + controls.dynamics * (0.2 + burst*2.8 - 1)
                let direction = (controls.counterflow && role == 1 && lane % 2 == 1) || (controls.outerReverse && role == 2) ? -1.0 : 1.0
                // Incommensurate modulation, inspired by the reference's point oscillators.
                // Neighboring packets gather and separate rather than rotating as one rigid set.
                let frequency = 0.19 + 0.23 * (Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1)
                let cluster = controls.clustering * 0.11 * cos(time * frequency + Double(index) * 2.39996)
                let drive = ((controls.drive * 2 - 1) * 0.16 * laneSpeed * surge * direction + cluster) * rate
                let pull = -controls.attraction * 0.45 * sin((positions[index] - controls.center) * 2 * .pi)
                velocities[index] += (drive + pull * rate - velocities[index]) / mass * step
                positions[index] += velocities[index] * step
                positions[index] -= floor(positions[index])
            }
            let threshold = (5 + controls.linkRange * 40) / 360
            func weight(_ index: Int) -> Double {
                let lane = index / 4, slot = index % 4
                let rank = [0,2,1,3][slot]
                let active = min(1, max(0, 1 + controls.density * 3 - Double(rank)))
                let period = (10-controls.rhythmRate*7)*(1+Double(lane)*0.09+Double(slot)*0.13)
                let phase = (time/period+Double(lane)*0.19+Double(slot)*0.27).truncatingRemainder(dividingBy:1)
                let life = smooth(0,0.035,phase)*(1-smooth(0.66,0.98,phase))
                return active * (1 + controls.dynamics * (life-1))
            }
            proximity = 0
            for inner in 0..<4 { for outer in 0..<4 {
                let j = outer + (lineCount-1)*4, pair = inner*4 + outer
                let before = Self.wrapped(previous[inner]-previous[j])
                let after = Self.wrapped(positions[inner]-positions[j])
                let strength = min(weight(inner),weight(j))
                proximity = max(proximity,max(0,1-abs(after)/threshold)*strength)
                if Self.crossed(from:before,to:after,threshold:threshold) {
                    let fraction = abs(before) / max(abs(before)+abs(after),1e-12)
                    let angle = previous[inner] + Self.wrapped(positions[inner]-previous[inner]) * fraction
                    eventAngles[pair] = angle-floor(angle)
                    eventTimes[pair] = time-step+step*fraction
                    eventStrengths[pair] = strength
                    if strength >= 0.01 {
                        crossings.append(Crossing(angle:eventAngles[pair],strength:strength,time:eventTimes[pair]))
                    }
                }
            } }
        }
    }
}
