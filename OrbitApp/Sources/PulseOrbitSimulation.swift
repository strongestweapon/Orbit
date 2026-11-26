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
    static let accentOffset = lineCountOffset+1
    static let accentCapacity = 24
    static let traceOffset = accentOffset+accentCapacity*9+1
    static let traceCapacity = 16
    static let traceStride = 12
    static let uniformCount = traceOffset+traceCapacity*traceStride+3
    // Shared authored motion rules, independent of retired installation settings.
    static let motionUniforms: [Float] = [0.82,0.58,0.55,1]
    static let interactionUniforms: [Float] = [0.72,0.30,0.39,0.24,0,0.2,0.45,0.45,0.35]
    enum AccentKind: Int {case departure=1, breakthrough, newOrbit, completion}
    struct Accent {
        var kind: AccentKind
        var start: Double
        var duration: Double
        var angle: Double
        var velocity: Double
        var radius: Double
        var strength: Double
        var origin: Double
        var direction: Double
        var packed: [Float] {[Float(kind.rawValue),Float(start),Float(duration),Float(angle),Float(velocity),Float(radius),Float(strength),Float(origin),Float(direction)]}
    }
    private(set) var accents: [Accent] = []
    private var accentSerial = 0
    struct Trace {
        var start, duration, angle, velocity, radius, halfLength, strength, white, direction: Double
        var releaseStart = -1.0
        var releaseDuration = 2.4
        var releaseLevel = 1.0
        var packed: [Float] { [start,duration,angle,velocity,radius,halfLength,strength,white,direction,releaseStart,releaseDuration,releaseLevel].map(Float.init) }
        func level(at time: Double) -> Double {
            let age=time-start
            guard age>=0,age<duration else {return 0}
            if releaseStart>=0 {
                return releaseLevel*(1-PulseOrbitSimulation.smooth(0,releaseDuration,time-releaseStart))
            }
            return PulseOrbitSimulation.smooth(0,0.15,age)*(1-PulseOrbitSimulation.smooth(duration*0.42,duration,age))
        }
    }
    private(set) var traces: [Trace] = []
    private var traceSerial = 0
    private var lastTraceBirth = -100.0
    private var lastTraceCenter = -1.0
    var lineCount: Int { positions.count / 4 }
    private(set) var positions: [Double] = (0..<12).map { (index: Int) -> Double in
        let lane = Double(index / 4) * 0.38196601125
        let slot = [0.0,0.127,0.573,0.731][index % 4]
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
        if uniforms.count >= Self.accentOffset {
            let count = uniforms[Self.lineCountOffset].isFinite ? Int(min(Float(Self.maximumLineCount),max(Float(Self.defaultLineCount),uniforms[Self.lineCountOffset]))) : Self.defaultLineCount
            let extra = (count-Self.defaultLineCount)*4
            positions += uniforms[Self.extendedOffset..<(Self.extendedOffset+extra)].map(Double.init)
            velocities += uniforms[(Self.extendedOffset+Self.extraParticleCapacity)..<(Self.extendedOffset+Self.extraParticleCapacity+extra)].map(Double.init)
        }
        if uniforms.count >= Self.traceOffset {
            for slot in 0..<Self.accentCapacity {
                let v=uniforms[(Self.accentOffset+slot*9)..<(Self.accentOffset+(slot+1)*9)].map(Double.init)
                if let kind=AccentKind(rawValue:Int(v[0])),v[2]>0 {
                    accents.append(.init(kind:kind,start:v[1],duration:v[2],angle:v[3],velocity:v[4],radius:v[5],strength:v[6],origin:v[7],direction:v[8]))
                }
            }
            accentSerial=Int(uniforms[Self.traceOffset-1])
        }
        if uniforms.count >= Self.uniformCount {
            for slot in 0..<Self.traceCapacity {
                let offset=Self.traceOffset+slot*Self.traceStride
                let v=uniforms[offset..<(offset+Self.traceStride)].map(Double.init)
                if v[1]>0 {traces.append(.init(start:v[0],duration:v[1],angle:v[2],velocity:v[3],radius:v[4],halfLength:v[5],strength:v[6],white:v[7],direction:v[8],releaseStart:v[9],releaseDuration:v[10],releaseLevel:v[11]))}
            }
            traceSerial=Int(uniforms[Self.uniformCount-3])
            lastTraceBirth=Double(uniforms[Self.uniformCount-2])
            lastTraceCenter=Double(uniforms[Self.uniformCount-1])
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
    var accentUniforms: [Float] {
        accents.flatMap(\.packed)+[Float](repeating:0,count:(Self.accentCapacity-accents.count)*9)+[Float(accentSerial)]
    }
    var traceUniforms: [Float] {
        traces.flatMap(\.packed)+[Float](repeating:0,count:(Self.traceCapacity-traces.count)*Self.traceStride)
            + [Float(traceSerial),Float(lastTraceBirth),Float(lastTraceCenter)]
    }

    private mutating func leaveTrace(at angle: Double, radius: Double, direction: Double,
                                     white: Bool, strength: Double, duration: Double) {
        guard strength>0 else {return}
        // Only an explicit command creates a mark. Its motion and lifetime are
        // independent of all continuous controls after that command.
        if traces.count>=Self.traceCapacity {traces.removeFirst()}
        let variation=Self.rhythmRandom(traceSerial,0,91)
        traceSerial+=1
        let length=0.08+0.08*variation
        lastTraceBirth=time;lastTraceCenter=angle
        traces.append(.init(start:time,duration:duration,angle:angle-floor(angle),
                            velocity:direction*0.003,radius:min(0.80,max(0.20,radius)),halfLength:length,
                            strength:strength,white:white ? 1 : 0,direction:direction))
    }

    private mutating func releaseNearbyTraces(controls: Controls) {
        let nearby=traces.indices.filter {traces[$0].releaseStart<0 && abs(Self.wrapped(traces[$0].angle-controls.center))<0.22}
            .sorted {abs(Self.wrapped(traces[$0].angle-controls.center))<abs(Self.wrapped(traces[$1].angle-controls.center))}
        for i in nearby.prefix(4) {
            traces[i].releaseLevel=traces[i].level(at:time)
            traces[i].releaseStart=time
            traces[i].releaseDuration=min(2.4,max(0.15,traces[i].duration-(time-traces[i].start)))
            // Once released, this unused drift-direction slot holds the target
            // captured by the completion command, not a live parameter binding.
            traces[i].direction=controls.center
        }
    }

    /// Each command owns its lifetime and trajectory, including same-frame repeats.
    /// Only a full voice pool steals the oldest voice; no merge or delayed queue.
    @discardableResult
    mutating func accent(_ kind: AccentKind, controls: Controls, strength: Double = 1) -> Accent {
        accents.removeAll {time-$0.start >= $0.duration}
        let power=max(0,min(1,strength.isFinite ? strength : 1))
        if accents.count>=Self.accentCapacity {
            accents.removeFirst()
        }
        let lane=accentSerial%3
        // Interleave radii rather than stacking rapid hits on the same three tracks.
        let radiusSlot=(accentSerial*7)%Self.accentCapacity
        let counterDirection=accentSerial%2==0 ? 1.0 : -1.0
        accentSerial+=1
        let direction=(controls.drive<0.5 ? -1.0 : 1.0)*counterDirection
        let duration:Double = kind == .departure ? 4.5 : kind == .breakthrough ? 3.6 : kind == .newOrbit ? 7 : 4
        let origin=kind == .completion ? positions[lane*4] : controls.center
        let radius=kind == .newOrbit ? Self.laneRadius(lineCount-1) : 0.10+0.80*Double(radiusSlot)/Double(Self.accentCapacity-1)
        accents.append(.init(kind:kind,start:time,duration:duration,angle:origin,
                             velocity:kind == .completion ? velocities[lane*4] : 0,
                             radius:radius,strength:power,origin:origin,direction:direction))
        if kind == .completion {if power>0 {releaseNearbyTraces(controls:controls)}}
        else {
            leaveTrace(at:controls.center,radius:radius,direction:counterDirection,white:kind == .breakthrough,
                       strength:power,duration:kind == .breakthrough ? 3.6 : kind == .newOrbit ? 10 : 8)
        }
        return accents[accents.count-1]
    }
    static func laneRadius(_ lane: Int) -> Double {
        [0.18,0.5,0.82,0.34,0.66,0.1,0.9,0.26,0.74,0.58][min(9,max(0,lane))]
    }

    func writeState(to packed: inout [Float]) {
        precondition(packed.count == Self.uniformCount)
        packed.replaceSubrange(24..<48, with: uniforms)
        packed[51] = Float(time)
        packed.replaceSubrange(Self.eventOffset..<Self.extendedOffset, with: eventUniforms)
        packed.replaceSubrange(Self.extendedOffset..<Self.accentOffset, with: extendedUniforms)
        packed.replaceSubrange(Self.accentOffset..<Self.traceOffset,with:accentUniforms)
        packed.replaceSubrange(Self.traceOffset..<Self.uniformCount,with:traceUniforms)
    }

    static func wrapped(_ turns: Double) -> Double { turns - floor(turns + 0.5) }
    // Used only for fixed spatial spacing; no clock-driven emission schedule.
    static func rhythmRandom(_ cycle: Int, _ lane: Int, _ salt: Int) -> Double {
        var x = UInt32(truncatingIfNeeded: cycle) &* 109 &+ UInt32(lane) &* 37 &+ UInt32(salt) &+ 1
        x = (x ^ (x >> 16)) &* 0x7feb352d
        x = (x ^ (x >> 15)) &* 0x846ca68b
        x ^= x >> 16
        return Double(x & 0x00ffffff) / 16777216
    }
    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1,max(0,(x-a)/(b-a))); return t*t*(3-2*t)
    }
    var motionEnergy: Double {
        accents.reduce(0) { value,accent in
            let age=time-accent.start
            guard age>=0,age<accent.duration else {return value}
            return max(value,Self.smooth(0,0.18,age)
                * (1-Self.smooth(accent.duration-1.4,accent.duration,age))*accent.strength)
        }
    }
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
            for i in accents.indices {
                let age=time-accents[i].start
                let pull = -controls.attraction*0.25*sin((accents[i].angle-controls.center)*2 * .pi)
                let pace=0.78+0.45*accents[i].radius
                let target:Double
                switch accents[i].kind {
                case .departure: target=accents[i].direction*0.20*pace*smooth(0,0.8,age)+pull
                case .breakthrough: target=accents[i].direction*0.34*pace*smooth(0,0.35,age)
                case .newOrbit: target=accents[i].direction*0.15*pace
                case .completion: target=Self.wrapped(controls.center-accents[i].angle)*2.2
                }
                accents[i].velocity += (target-accents[i].velocity)*step/(0.18+controls.inertia*0.4)
                accents[i].angle += accents[i].velocity*step
                accents[i].angle -= floor(accents[i].angle)
            }
            accents.removeAll {time-$0.start >= $0.duration}
            let energy=motionEnergy
            // Short, legible phrases keep moving at rest. Commands amplify the
            // forces; the clock never schedules an autonomous acceleration.
            let eventAge=time-(accents.map(\.start).min() ?? time)
            for index in positions.indices {
                let lane = index / 4
                let slot = index % 4
                let role = lane == 0 ? 0 : (lane == 2 ? 2 : 1)
                let laneSpeed = [0.72,1.45,1.08][role]
                let rate = controls.laneRates[role] * 3
                if rate == 0 { velocities[index] = 0; continue }
                let direction = (controls.counterflow && role == 1 && lane % 2 == 1) || (controls.outerReverse && role == 2) ? -1.0 : 1.0
                // Incommensurate modulation, inspired by the reference's point oscillators.
                // Neighboring packets gather and separate rather than rotating as one rigid set.
                let frequency = 0.19 + 0.23 * (Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1)
                let cluster = controls.clustering * 0.16 * abs(controls.drive*2-1)
                    * (1-controls.attraction*0.6)
                    * cos(eventAge * frequency + Double(index) * 2.39996)
                let gather = (1-energy)*controls.dynamics
                let spacing = (0.015+0.095*(1-gather))*(0.5+Self.rhythmRandom(0,lane,slot+21))
                let groupPull = slot == 0 ? 0 : -sin((positions[index]-positions[lane*4]+direction*Double(slot)*spacing)*2 * .pi)
                    * gather*controls.clustering*0.4*abs(controls.drive*2-1)
                let drive = ((controls.drive * 2 - 1) * (0.200+0.120*energy) * laneSpeed * direction
                    + (cluster + groupPull)*energy) * rate
                let pull = -controls.attraction * (0.060+1.040*energy) * sin((positions[index] - controls.center) * 2 * .pi)
                let response=max(0.08,mass*(0.15+0.85*energy))
                velocities[index] += (drive + pull * rate - velocities[index]) / response * step
                positions[index] += velocities[index] * step
                positions[index] -= floor(positions[index])
            }
            for i in traces.indices {
                if traces[i].releaseStart>=0 {
                    let target=Self.wrapped(traces[i].direction-traces[i].angle)*1.8
                    traces[i].velocity+=(target-traces[i].velocity)*step/0.35
                }
                traces[i].angle+=traces[i].velocity*step
                traces[i].angle-=floor(traces[i].angle)
            }
            traces.removeAll { time-$0.start >= $0.duration || ($0.releaseStart>=0 && time-$0.releaseStart >= $0.releaseDuration) }
            // Visual traces are not sound cues. Crossing flashes/OSC events belong
            // to triggered motion, even if resting paths happen to overlap.
            if energy<=0 {proximity=0;continue}
            let threshold = (5 + controls.linkRange * 40) / 360
            func weight(_ index: Int) -> Double {
                let lane = index / 4, slot = index % 4
                guard slot<3,lane<3 else {return 0}
                let active = min(1, max(0, 1 + controls.density * 8 - Double(lane+slot*3)))
                return active * (slot == 0 ? 1.0 : 0.70+0.30*energy)
            }
            proximity = 0
            for inner in 0..<4 { for outer in 0..<4 {
                let j = outer + 8, pair = inner*4 + outer
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

/// Only spontaneous simulation crossings are rate limited. User/OSC commands and
/// continuous-to-trigger mappings never pass through this gate.
struct PulseCueGate {
    private(set) var lastCue: Double?
    mutating func accept(at time: Double) -> Bool {
        guard time.isFinite,lastCue.map({time-$0>=6}) ?? true else {return false}
        lastCue=time;return true
    }
}
