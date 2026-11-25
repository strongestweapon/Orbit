import Foundation

@main struct PulseOrbitChecks {
    static func advance(_ sim: inout PulseOrbitSimulation, seconds: Double, fps: Int = 60,
                        drive: Double = 0.72, gravity: Double = 0, inertia: Double = 0.55, center: Double = 0,
                        dynamics: Double = 0, counterflow: Bool = false) {
        for _ in 0..<Int(seconds * Double(fps)) {
            sim.advance(by: 1 / Double(fps), controls: .init(drive:drive, attraction:gravity, inertia:inertia, center:center,
                                                          dynamics:dynamics,counterflow:counterflow,clustering:0,outerReverse:false))
        }
    }
    static func main() {
        var clockwise = PulseOrbitSimulation(), counter = PulseOrbitSimulation()
        advance(&clockwise, seconds:10, drive:1)
        advance(&counter, seconds:10, drive:0)
        precondition(clockwise.velocities.allSatisfy { $0 > 0 })
        precondition(counter.velocities.allSatisfy { $0 < 0 })
        var fast = clockwise, slow = clockwise
        advance(&fast, seconds:1, drive:0, inertia:0)
        advance(&slow, seconds:1, drive:0, inertia:1)
        precondition(fast.velocities.allSatisfy { $0 < 0 })
        precondition(slow.velocities.allSatisfy { $0 > 0 }, "Inertia must preserve prior motion before reversing")
        advance(&slow, seconds:15, drive:0, inertia:1)
        precondition(slow.velocities.allSatisfy { $0 < 0 })
        var gathered = PulseOrbitSimulation()
        advance(&gathered, seconds:90, drive:0.5, gravity:1, inertia:0.4, center:0.25)
        precondition(gathered.positions.allSatisfy { abs($0 - 0.25) < 0.001 }, "Attraction must converge from both directions")
        precondition(gathered.velocities.allSatisfy { abs($0) < 0.0001 })
        var lowFPS = PulseOrbitSimulation(), highFPS = PulseOrbitSimulation()
        advance(&lowFPS, seconds:20, fps:30, gravity:0.3, dynamics:0.85,counterflow:true)
        advance(&highFPS, seconds:20, fps:180, gravity:0.3, dynamics:0.85,counterflow:true)
        precondition(zip(lowFPS.uniforms,highFPS.uniforms).allSatisfy { abs($0 - $1) < 0.00001 }, "Render count must not change motion")
        let paused = lowFPS.uniforms
        lowFPS.advance(by:0, controls:.init(drive:0,attraction:1,inertia:0,center:1))
        precondition(paused == lowFPS.uniforms)
        precondition(PulseOrbitSimulation(uniforms:[Float](repeating:0,count:24)+paused).uniforms == paused)
        var snapshot = [Float](repeating:0,count:24) + lowFPS.uniforms + [0,1,0,Float(lowFPS.time),0.85,0.55,0.65,1]
        var resumed = PulseOrbitSimulation(uniforms:snapshot)
        advance(&lowFPS,seconds:5,gravity:0.3,dynamics:0.85,counterflow:true)
        advance(&resumed,seconds:5,gravity:0.3,dynamics:0.85,counterflow:true)
        precondition(zip(lowFPS.uniforms,resumed.uniforms).allSatisfy { abs($0-$1)<0.00001 }, "Benchmark must resume rhythm and physics from the same clock")
        // New state includes event history and fractional fixed-step time.
        var fusion = PulseOrbitSimulation()
        let fusionControls = PulseOrbitSimulation.Controls(drive:0.8,attraction:0.1,inertia:0.4,center:0)
        for _ in 0..<720 { fusion.advance(by:1.0/60,controls:fusionControls) }
        precondition(fusion.eventStrengths.contains { $0 > 0 }, "Opposing orbits must actually cross")
        fusion.advance(by:0.003,controls:fusionControls)
        var full = [Float](repeating:0,count:PulseOrbitSimulation.uniformCount)
        fusion.writeState(to:&full)
        var copy = PulseOrbitSimulation(uniforms:full)
        for _ in 0..<120 {
            fusion.advance(by:1.0/60,controls:fusionControls)
            copy.advance(by:1.0/60,controls:fusionControls)
        }
        precondition(zip(fusion.uniforms,copy.uniforms).allSatisfy { abs($0-$1)<0.00002 })
        precondition(zip(fusion.eventUniforms,copy.eventUniforms).allSatisfy { abs($0-$1)<0.00002 }, "Benchmark must preserve recent crossing flashes")
        var at30=PulseOrbitSimulation(),at180=PulseOrbitSimulation()
        for _ in 0..<600 { at30.advance(by:1.0/30,controls:fusionControls) }
        for _ in 0..<3600 { at180.advance(by:1.0/180,controls:fusionControls) }
        precondition(at30.uniforms==at180.uniforms && zip(at30.eventUniforms,at180.eventUniforms).allSatisfy { abs($0-$1)<0.0000001 }, "Frame rates may differ only by floating-point remainder rounding")
        precondition(PulseOrbitSimulation.crossed(from:-0.002,to:0.002,threshold:0.05))
        precondition(PulseOrbitSimulation.crossed(from:0.002,to:0,threshold:0.05))
        precondition(!PulseOrbitSimulation.crossed(from:0,to:0.002,threshold:0.05))
        precondition(!PulseOrbitSimulation.crossed(from:0.499,to:-0.499,threshold:0.05), "Antipode wrap must not flash")
        // A genuine alignment crossing twelve o'clock must not be lost at the seam.
        var seed = [Float](repeating:0,count:PulseOrbitSimulation.uniformCount)
        PulseOrbitSimulation().writeState(to:&seed)
        seed[24]=0.999;seed[32]=0.001;seed[36]=0.3;seed[44] = -0.3
        var seam=PulseOrbitSimulation(uniforms:seed)
        seam.advance(by:1.0/60,controls:.init(drive:1,attraction:0,inertia:0.5,center:0,dynamics:0,clustering:0))
        precondition(seam.eventTimes[0]>0 && seam.eventStrengths[0]>0)
        precondition(abs(PulseOrbitSimulation.wrapped(seam.eventAngles[0]))<0.002)
        let stopped = fusion.positions
        fusion.advance(by:0.2,controls:.init(drive:1,attraction:1,inertia:0,center:0,laneRates:[0,0,0]))
        precondition(fusion.positions==stopped && fusion.velocities.allSatisfy { $0==0 })
        snapshot[52]=0.31;snapshot[53]=0.72;snapshot[55]=0
        let controls=PulseOrbitSimulation.Controls(uniforms:snapshot)
        precondition(abs(controls.dynamics-0.31)<0.00001 && abs(controls.rhythmRate-0.72)<0.00001 && !controls.counterflow)
        var rhythmic = PulseOrbitSimulation()
        var speeds:[Double]=[]
        for _ in 0..<24 {
            advance(&rhythmic,seconds:1,drive:1,dynamics:1,counterflow:true)
            speeds.append(rhythmic.velocities[0])
        }
        precondition(speeds.max()! > speeds.min()!*2, "Packets must accelerate and brake, not drift at a fixed speed")
        precondition(rhythmic.velocities[0]>0 && rhythmic.velocities[4]<0 && rhythmic.velocities[8]>0)
        var stall = clockwise
        stall.advance(by:1e10,controls:.init(drive:1,attraction:1,inertia:0,center:0))
        precondition(stall.uniforms.allSatisfy(\.isFinite) && stall.positions.allSatisfy { (0..<1).contains($0) })
        precondition(PulseOrbitSimulation().uniforms == PulseOrbitSimulation().uniforms)
        var expanded=PulseOrbitSimulation()
        advance(&expanded,seconds:2)
        let oldPositions=expanded.positions,oldClock=expanded.time
        for expected in 4...10 {
            expanded.addLine()
            precondition(expanded.lineCount==expected && expanded.positions.count==expected*4)
            precondition(Array(expanded.positions.prefix(12))==oldPositions && expanded.time==oldClock)
            precondition(expanded.takeCrossings().isEmpty,"Adding lines must not emit phantom crossings")
        }
        var expandedSnapshot=[Float](repeating:0,count:PulseOrbitSimulation.uniformCount)
        expanded.writeState(to:&expandedSnapshot)
        precondition(expandedSnapshot.count==171 && expandedSnapshot[PulseOrbitSimulation.lineCountOffset]==10)
        var expandedCopy=PulseOrbitSimulation(uniforms:expandedSnapshot)
        advance(&expanded,seconds:4);advance(&expandedCopy,seconds:4)
        precondition(zip(expanded.positions,expandedCopy.positions).allSatisfy {abs($0-$1)<0.00002})
        precondition(expanded.velocities.count==40 && expanded.velocities.allSatisfy {$0>0})
        expanded.addLine();precondition(expanded.lineCount==3)
        expanded.addLine(limit:4);precondition(expanded.lineCount==4)
        expanded.addLine(limit:4);precondition(expanded.lineCount==3)
        var many30=PulseOrbitSimulation(),many180=PulseOrbitSimulation()
        many30.setLineCount(10);many180.setLineCount(10)
        advance(&many30,seconds:10,fps:30,gravity:0.3,dynamics:0.85,counterflow:true)
        advance(&many180,seconds:10,fps:180,gravity:0.3,dynamics:0.85,counterflow:true)
        precondition(zip(many30.positions,many180.positions).allSatisfy {abs($0-$1)<0.00001})
        print("PASS: clockwise/counterclockwise, inertial reversal, attraction convergence, rhythmic acceleration, counterflow, 30/180 FPS equivalence, pause, resumable simulation clock, bounded catch-up, clustering, per-lane stop, true crossings, antipode rejection, seam events and event snapshot resume, 3–10 line cycling, state preservation, expanded snapshot and FPS equivalence")
    }
}
