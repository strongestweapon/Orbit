import Foundation

@main struct PulseOrbitChecks {
    static func advance(_ sim: inout PulseOrbitSimulation, seconds: Double, fps: Int = 60,
                        drive: Double = 0.72, gravity: Double = 0, inertia: Double = 0.55, center: Double = 0,
                        dynamics: Double = 0, counterflow: Bool = false) {
        for _ in 0..<Int(seconds * Double(fps)) {
            sim.advance(by: 1 / Double(fps), controls: .init(drive:drive, attraction:gravity, inertia:inertia, center:center,
                                                          dynamics:dynamics,counterflow:counterflow))
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
        print("PASS: clockwise/counterclockwise, inertial reversal, attraction convergence, rhythmic acceleration, counterflow, 30/180 FPS equivalence, pause, resumable simulation clock, bounded catch-up")
    }
}
