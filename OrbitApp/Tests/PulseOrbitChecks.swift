import Foundation

@main struct PulseOrbitChecks {
    static let normal=PulseOrbitSimulation.Controls(drive:0.78,attraction:0.12,inertia:0.55,center:0.15,
        dynamics:0.82,rhythmRate:0.58,counterflow:true,clustering:0.72,laneRates:[0.30,0.39,0.24],outerReverse:false,density:0.65)
    static func advance(_ sim: inout PulseOrbitSimulation,seconds:Double,fps:Int=60,
                        controls:PulseOrbitSimulation.Controls=normal) {
        for _ in 0..<Int((seconds*Double(fps)).rounded()) {sim.advance(by:1/Double(fps),controls:controls)}
    }
    static func snapshot(_ sim:PulseOrbitSimulation)->[Float] {
        var state=[Float](repeating:0,count:PulseOrbitSimulation.uniformCount)
        sim.writeState(to:&state);return state
    }
    static func main() {
        // Even extreme controls retain a bounded current. Only commands can
        // amplify it into an energetic performance.
        var idle=PulseOrbitSimulation()
        let resting=idle.positions
        for control in [normal,.init(drive:1,attraction:1,inertia:0,center:0.81),
                        .init(drive:0,attraction:0.8,inertia:1,center:0.05)] {
            for _ in 0..<1200 {
                idle.advance(by:0.25,controls:control)
                precondition(idle.velocities.allSatisfy {abs($0)<0.36})
                precondition(idle.takeCrossings().isEmpty && idle.motionEnergy==0 && idle.proximity==0)
            }
        }
        precondition(idle.time>899 && idle.positions != resting,"Quiet current must move without an autoplay burst")
        for kind in [PulseOrbitSimulation.AccentKind.departure,.breakthrough,.newOrbit,.completion] {
            var sim=PulseOrbitSimulation()
            advance(&sim,seconds:30)
            let initial=sim.uniforms
            let event=sim.accent(kind,controls:normal)
            let paused=snapshot(sim)
            sim.advance(by:0,controls:normal)
            precondition(snapshot(sim)==paused,"Pause freezes event age and all positions")
            advance(&sim,seconds:1)
            precondition(sim.motionEnergy>0.9 && sim.uniforms != initial,"A command must wake the background")
            precondition(abs(PulseOrbitSimulation.wrapped(sim.accents[0].angle-event.origin))>0.001,"Each accent must move")
            advance(&sim,seconds:event.duration+0.5)
            precondition(sim.accents.isEmpty && sim.motionEnergy==0 && sim.velocities.allSatisfy {abs($0)<0.21})
            let settled=sim.uniforms
            for _ in 0..<3600 {
                sim.advance(by:1.0/60,controls:normal)
                precondition(sim.velocities.allSatisfy {abs($0)<0.21} && sim.takeCrossings().isEmpty,"Expired commands must return to quiet current without sound cues")
            }
            precondition(sim.uniforms != settled,"Resting current must not be a frozen image")
        }
        // Direction, gravity and inertia still govern motion during an event.
        let cw=PulseOrbitSimulation.Controls(drive:1,attraction:0,inertia:0.55,center:0,counterflow:false,clustering:0,outerReverse:false)
        let ccw=PulseOrbitSimulation.Controls(drive:0,attraction:0,inertia:0.55,center:0,counterflow:false,clustering:0,outerReverse:false)
        var clockwise=PulseOrbitSimulation(),counter=PulseOrbitSimulation()
        clockwise.accent(.newOrbit,controls:cw);counter.accent(.newOrbit,controls:ccw)
        advance(&clockwise,seconds:2,controls:cw);advance(&counter,seconds:2,controls:ccw)
        precondition(clockwise.velocities.allSatisfy {$0>0} && counter.velocities.allSatisfy {$0<0})
        var fast=clockwise,slow=clockwise,fastControl=ccw,slowControl=ccw
        fastControl.inertia=0;slowControl.inertia=1
        advance(&fast,seconds:1,controls:fastControl);advance(&slow,seconds:1,controls:slowControl)
        precondition(fast.velocities.allSatisfy {$0<0} && slow.velocities.allSatisfy {$0>0},"Inertia must delay reversal")
        let gravity=PulseOrbitSimulation.Controls(drive:0.5,attraction:1,inertia:0.4,center:0.25,clustering:0)
        var gathered=PulseOrbitSimulation()
        for _ in 0..<15 {gathered.accent(.newOrbit,controls:gravity);advance(&gathered,seconds:4,controls:gravity)}
        precondition(gathered.positions.allSatisfy {abs($0-0.25)<0.001},"Active gravity converges from both sides")
        var low=PulseOrbitSimulation(),high=PulseOrbitSimulation()
        for simKind in [PulseOrbitSimulation.AccentKind.departure,.newOrbit,.completion] {
            low.accent(simKind,controls:normal);high.accent(simKind,controls:normal)
            advance(&low,seconds:2,fps:30);advance(&high,seconds:2,fps:180)
        }
        precondition(zip(low.uniforms,high.uniforms).allSatisfy {abs($0-$1)<0.00001})
        low.advance(by:0.003,controls:normal)
        var resumed=PulseOrbitSimulation(uniforms:snapshot(low))
        advance(&low,seconds:1,fps:30);advance(&resumed,seconds:1,fps:180)
        precondition(zip(low.uniforms,resumed.uniforms).allSatisfy {abs($0-$1)<0.00002})
        precondition(zip(low.accentUniforms,resumed.accentUniforms).allSatisfy {abs($0-$1)<0.00002})
        precondition(zip(low.traceUniforms,resumed.traceUniforms).allSatisfy {abs($0-$1)<0.0002})
        advance(&low,seconds:15);advance(&resumed,seconds:15)
        precondition(low.motionEnergy==0 && resumed.motionEnergy==0)
        var repeated=PulseOrbitSimulation()
        for _ in 0..<20 {repeated.accent(.departure,controls:normal)}
        precondition(repeated.accents.count==20 && Set(repeated.accents.map(\.radius)).count==20)
        precondition(Set(repeated.accents.map(\.direction)).count==2)
        advance(&repeated,seconds:1)
        precondition(Set(repeated.accents.map(\.angle)).count==20)
        let restored=PulseOrbitSimulation(uniforms:snapshot(repeated))
        precondition(zip(restored.accentUniforms,repeated.accentUniforms).allSatisfy {abs($0-$1)<0.00001})
        for _ in 0..<100 {repeated.accent(.breakthrough,controls:normal);precondition(repeated.accents.count<=24)}
        advance(&repeated,seconds:8)
        let settled=repeated.positions
        advance(&repeated,seconds:30)
        precondition(repeated.accents.isEmpty && repeated.positions != settled && repeated.velocities.allSatisfy {abs($0)<0.21},"After the burst only a quiet current remains")
        var staggered=PulseOrbitSimulation()
        staggered.accent(.departure,controls:normal);advance(&staggered,seconds:3)
        staggered.accent(.breakthrough,controls:normal);advance(&staggered,seconds:2)
        precondition(staggered.accents.count==1 && staggered.motionEnergy>0,"A newer event survives the older one's expiry")
        advance(&staggered,seconds:2);precondition(staggered.motionEnergy==0)
        var expanded=PulseOrbitSimulation()
        for expected in 4...10 {expanded.addLine();precondition(expanded.lineCount==expected)}
        let expandedCopy=PulseOrbitSimulation(uniforms:snapshot(expanded))
        precondition(expandedCopy.positions==expanded.positions.map {Double(Float($0))})
        expanded.addLine();precondition(expanded.lineCount==3)
        expanded.addLine(limit:4);precondition(expanded.lineCount==4)
        expanded.addLine(limit:4);precondition(expanded.lineCount==3)
        var stopped=clockwise
        let beforeStop=stopped.positions
        stopped.advance(by:0.2,controls:.init(drive:1,attraction:1,inertia:0,center:0,laneRates:[0,0,0]))
        precondition(stopped.positions==beforeStop && stopped.velocities.allSatisfy {$0==0})
        precondition(PulseOrbitSimulation.crossed(from:-0.002,to:0.002,threshold:0.05))
        precondition(!PulseOrbitSimulation.crossed(from:0.499,to:-0.499,threshold:0.05))
        precondition(!PulseOrbitSimulation.crossed(from:0,to:0.002,threshold:0.05))
        var gate=PulseCueGate()
        precondition(gate.accept(at:10) && !gate.accept(at:15.99) && gate.accept(at:16))
        let restingControl=PulseOrbitSimulation.Controls(drive:0.5,attraction:0,inertia:0.55,center:0.15)
        var noTriggers=PulseOrbitSimulation()
        for frame in 0..<3600 {
            let v=Double(frame%120)/119
            let controls=PulseOrbitSimulation.Controls(drive:v,attraction:1-v,inertia:v,center:v,density:v)
            noTriggers.advance(by:1.0/60,controls:controls)
            precondition(noTriggers.traces.isEmpty,"Neither continuous inputs nor passages may create perpendicular marks")
        }
        var fixed=PulseOrbitSimulation()
        fixed.accent(.departure,controls:normal)
        var changed=fixed
        advance(&fixed,seconds:2,controls:normal)
        advance(&changed,seconds:2,controls:.init(drive:0,attraction:1,inertia:0,center:0.8,density:0))
        precondition(fixed.traceUniforms==changed.traceUniforms,"All five continuous controls must leave an existing mark unchanged")
        fixed.accent(.completion,controls:normal);changed.accent(.completion,controls:normal)
        advance(&fixed,seconds:1,controls:normal)
        advance(&changed,seconds:1,controls:.init(drive:1,attraction:0,inertia:1,center:0.6,density:1))
        precondition(fixed.traceUniforms==changed.traceUniforms,"Completion captures its target instead of following a continuous parameter")
        for kind in [PulseOrbitSimulation.AccentKind.departure,.breakthrough,.newOrbit] {
            var mark=PulseOrbitSimulation()
            mark.accent(kind,controls:normal)
            precondition(mark.traces.count==1)
            let lifetime=mark.traces[0].duration
            advance(&mark,seconds:lifetime-0.1)
            precondition(mark.traces.count==1)
            advance(&mark,seconds:0.2)
            precondition(mark.traces.isEmpty,"Every triggered mark must expire independently")
        }
        var commanded=PulseOrbitSimulation()
        for _ in 0..<20 {commanded.accent(.departure,controls:restingControl)}
        precondition(commanded.traces.count==16 && commanded.accents.count==20,"Rapid commands retain independent bounded memories and accent voices")
        advance(&commanded,seconds:1,controls:restingControl)
        commanded.accent(.completion,controls:restingControl)
        precondition(commanded.traces.filter {$0.releaseStart>=0}.count==4)
        advance(&commanded,seconds:2.5,controls:restingControl)
        precondition(commanded.traces.count==12,"Completion releases only its selected nearby memories")
        advance(&commanded,seconds:8,controls:restingControl)
        precondition(commanded.traces.isEmpty)
        print("PASS: trigger-only perpendicular marks, no continuous-control coupling, captured completion target, independent expiry, 16-mark bound and snapshot continuity")
        print("PASS: 15 minutes of bounded quiet drift; all four commands accelerate then return to slow current; no spontaneous crossing cues")
        print("PASS: event-driven direction/gravity/inertia, pause/snapshot/30–180 FPS, 20 separate rapid voices, 24-voice bound, overlapping lifetimes, 3–10 lines and no backlog")
    }
}
