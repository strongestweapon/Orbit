import AppKit
import Network
import Darwin

final class PulseInbox {
    private let lock = NSLock()
    private var packets: [Data] = []
    private var port: UInt16?
    private var connections: [NWConnection] = []
    func receive(_ data: Data) { lock.lock(); packets.append(data); lock.unlock() }
    func ready(_ value: UInt16) { lock.lock(); port=value; lock.unlock() }
    func hold(_ value: NWConnection) { lock.lock(); connections.append(value); lock.unlock() }
    func snapshot() -> ([Data],UInt16?) { lock.lock(); defer {lock.unlock()}; return (packets,port) }
    func latest(_ address: String) -> Double? {
        snapshot().0.flatMap { OSCDecoder.decode($0) }.last { $0.address == address }?.values.first
    }
}

/// UDP sensor -> actual model -> UDP receiver. Isolated preferences and local UDP.
@main struct PulseOSCChecks {
    static func pump(_ seconds: Double) { RunLoop.main.run(until:Date().addingTimeInterval(seconds)) }
    static func wait(_ message: String, _ predicate: () -> Bool) {
        let end=Date().addingTimeInterval(12)
        while !predicate() { precondition(Date()<end,message);pump(0.01) }
    }
    static func receive(_ connection: NWConnection, _ inbox: PulseInbox) {
        connection.receiveMessage { data,_,_,error in
            if let data { inbox.receive(data) }
            if error == nil { receive(connection,inbox) }
        }
    }
    static func freePort() -> UInt16 {
        let fd=socket(AF_INET,SOCK_DGRAM,0);precondition(fd>=0);defer {Darwin.close(fd)}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET)
        address.sin_addr.s_addr=inet_addr("127.0.0.1")
        let result=withUnsafePointer(to:&address) { ptr in ptr.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        precondition(result==0)
        var size=socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to:&address) { ptr in _=ptr.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&size) } }
        return UInt16(bigEndian:address.sin_port)
    }
    static func main() throws {
        let inbox=PulseInbox(),queue=DispatchQueue(label:"orbit-pulse-loopback")
        let listener=try NWListener(using:.udp,on:.any)
        listener.stateUpdateHandler={ state in if case .ready=state,let port=listener.port {inbox.ready(port.rawValue)} }
        listener.newConnectionHandler={connection in inbox.hold(connection);connection.start(queue:queue);receive(connection,inbox)}
        listener.start(queue:queue);defer {listener.cancel()}
        wait("loopback listener") {inbox.snapshot().1 != nil}
        let domain="studio.superless.Orbit.pulse-osc-test-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:domain)!
        defer {defaults.removePersistentDomain(forName:domain)}
        let bundle=Bundle(path:CommandLine.arguments[1])!
        let model=OrbitModel(defaults:defaults,resources:bundle,controlOutput:ControlOutput())
        defer {model.shutdownForTermination()}
        model.setOSCOutputDestination(.init(host:"127.0.0.1",port:Int(inbox.snapshot().1!)))
        model.selectedSceneID=PulseOrbitSimulation.sceneID;model.playing=false
        let controls=model.shaderParameters
        precondition(controls.count==23)
        precondition(model.sensors.isEmpty)
        for control in controls {
            model.setRoute(control.id) {
                $0.input.directOSCAddress="/qa/in/"+control.id
                $0.output.enabled=true;$0.output.configured=true;$0.output.transport = .osc

                $0.output.address="/qa/out/"+control.id;$0.output.minimum=0;$0.output.maximum=1
            }
        }
        model.port=String(freePort());model.startOSC()
        wait("actual OSC receiver") {model.oscRunning}
        model.controlOutputEnabled=true
        let source=NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:UInt16(model.port)!)!,using:.udp)
        source.start(queue:queue);defer {source.cancel()}
        let messages=controls.map { OSCEncoder.floatMessage(address:"/qa/in/"+$0.id,value:0.62)! }
        source.send(content:OSCEncoder.immediateBundle(messages),completion:.contentProcessed({_ in }))
        wait("all 23 direct OSC inputs") { controls.allSatisfy {abs(model.normalizedParameterValue($0.id)-($0.isSwitch == true ? 1:0.62))<0.00001} }
        wait("all 23 real output floats") {controls.allSatisfy {abs((inbox.latest("/qa/out/"+$0.id) ?? -1)-($0.isSwitch == true ? 1:0.62))<0.00001}}
        // Switches honor the 0.5 threshold without smoothing; reject integer/NaN input.
        for value in [Float(0.49),Float(0.5)] {
            source.send(content:OSCEncoder.floatMessage(address:"/qa/in/outerReverse",value:value),completion:.contentProcessed({_ in }))
            wait("switch threshold") {model.normalizedParameterValue("outerReverse") == (value>=0.5 ? 1:0)}
        }
        var integer=OSCEncoder.floatMessage(address:"/qa/in/clustering",value:0.2)!
        if let i=integer.firstIndex(of:102) { integer[i]=105 }
        source.send(content:integer,completion:.contentProcessed({_ in }));pump(0.1)
        precondition(abs(model.normalizedParameterValue("clustering")-0.62)<0.00001)
        // Retain custom input/output addresses across process-equivalent settings reload.
        model.save()
        let restored=OrbitModel(defaults:defaults,resources:bundle,controlOutput:ControlOutput())
        defer {restored.shutdownForTermination()}
        restored.selectedSceneID=PulseOrbitSimulation.sceneID
        precondition(restored.route(for:"waveTravel").output.address=="/qa/out/waveTravel")
        precondition(restored.route(for:"outerReverse").input.directOSCAddress=="/qa/in/outerReverse")
        precondition(restored.sensors.isEmpty)

        // Disable direct input; exercise real crossings instead of synthetic output calls.
        for control in controls {model.setRoute(control.id) {$0.input.directOSCEnabled=false;$0.output.enabled=false}}
        model.resetSceneAppearance()
        model.setNormalizedParameterValue("attraction",0)
        model.setNormalizedParameterValue("directionDrive",1)
        model.setNormalizedParameterValue("rhythmAmount",0)
        model.setNormalizedParameterValue("clustering",0)
        model.setNormalizedParameterValue("speed",1)
        for spec in PulseOrbitOutputs.specs {
            precondition(model.route(for:spec.id).output.transport == .osc)
            model.setRoute(spec.id) {
                $0.input.enabled=true // Must be rejected: simulation signals are output-only.
                $0.output.enabled=true;$0.output.configured=true
                $0.output.address="/qa/event/"+spec.id
            }
            precondition(!model.route(for:spec.id).input.enabled)
        }
        model.save()
        let saved=try JSONDecoder().decode(StoredSettings.self,from:defaults.data(forKey:"OrbitSettings.v1")!)
        for spec in PulseOrbitOutputs.specs {
            let route=saved.scenes[PulseOrbitSimulation.sceneID]!.parameterRoutes![spec.id]!
            precondition(route.output.address=="/qa/event/"+spec.id && route.output.enabled && !route.input.enabled)
        }
        let controlsBeforePlayback=model.parameterValues
        model.playing=true
        let deadline=Date().addingTimeInterval(6)
        while Date()<deadline && model.pulseCrossingCount<5 {
            _=model.uniforms(width:1920,height:1080,view:1);pump(0.01)
        }
        model.playing=false
        precondition(model.pulseCrossingCount>=5,"No actual crossing events")
        precondition(model.parameterValues==controlsBeforePlayback,"Live output telemetry must not invalidate shader controls")
        precondition(model.controlValue(PulseOrbitOutputs.proximity)>=0)
        let count=model.pulseCrossingCount
        func eventPackets() -> [Data] {inbox.snapshot().0.filter {OSCDecoder.decode($0).contains {$0.address=="/qa/event/crossingTrigger"}}}
        wait("one bundle per crossing") {eventPackets().count==count}
        for data in eventPackets() {
            precondition(data.starts(with:Data("#bundle\0".utf8)))
            let messages=OSCDecoder.decode(data)
            precondition(messages.map(\.address)==["/qa/event/crossingAngle","/qa/event/crossingStrength","/qa/event/crossingTrigger"])
            precondition(messages.last?.values==[1])
            precondition(messages.allSatisfy {$0.values.count==1 && (0...1).contains($0.values[0])})
        }
        pump(2.2);precondition(eventPackets().count==count,"Paused event outputs must not heartbeat")
        let expectedProximity=model.controlValue(PulseOrbitOutputs.proximity)
        let previousPacketCount=inbox.snapshot().0.count
        model.testControlOutput(PulseOrbitOutputs.proximity)
        wait("manual proximity test uses live simulation value") {
            inbox.snapshot().0.count>previousPacketCount && abs((inbox.latest("/qa/event/proximity") ?? -1)-expectedProximity)<0.00001
        }
        model.controlOutputEnabled=false;model.playing=true
        for _ in 0..<25 {_=model.uniforms(width:1920,height:1080,view:1);pump(0.01)}
        model.playing=false;model.controlOutputEnabled=true;pump(0.15)
        precondition(eventPackets().count==count,"Re-enabling output must not replay missed events")
        let cue=model.globalOSC.first {$0.sceneID==PulseOrbitSimulation.sceneID}!
        for expected in 1...3 {
            source.send(content:OSCEncoder.floatMessage(address:cue.address,value:1),completion:.contentProcessed({_ in }))
            wait("repeated scene trigger") {model.globalReceipts[cue.id]?.triggerCount==expected}
            precondition(model.pulseCrossingCount==0)
        }
        // Numeric simulation outputs can also send unit cues without changing their addresses.
        model.playing=false
        for key in [PulseOrbitOutputs.angle,PulseOrbitOutputs.strength,PulseOrbitOutputs.proximity] {
            let address=model.route(for:key).output.address
            model.setRoute(key) {$0.output.mode = .trigger}
            precondition(model.route(for:key).output.address==address && model.route(for:key).output.behavior == .trigger)
        }
        pump(0.1)
        let earlier=inbox.snapshot().0.count
        model.playing=true
        let end=Date().addingTimeInterval(6)
        while Date()<end && model.pulseCrossingCount<3 {
            _=model.uniforms(width:1920,height:1080,view:1);pump(0.01)
        }
        model.playing=false;pump(0.1)
        precondition(model.pulseCrossingCount>=3)
        let newMessages=inbox.snapshot().0.dropFirst(earlier).flatMap {OSCDecoder.decode($0)}
        for key in [PulseOrbitOutputs.angle,PulseOrbitOutputs.strength,PulseOrbitOutputs.proximity] {
            let messages=newMessages.filter {$0.address==model.route(for:key).output.address}
            precondition(!messages.isEmpty && messages.allSatisfy {$0.values==[1]},"Simulation cue payload: \(key)")
        }
        let settled=inbox.snapshot().0.count
        pump(2.2);precondition(inbox.snapshot().0.count==settled,"Held simulation values must not repeat triggers")
        model.testControlOutput(PulseOrbitOutputs.proximity)
        wait("simulation trigger send test") {inbox.snapshot().0.count==settled+1}
        precondition(inbox.latest(model.route(for:PulseOrbitOutputs.proximity).output.address)==1)
        print("PASS: 23 real UDP inputs -> normalized shader controls -> 23 UDP outputs, switches, integer rejection, persisted routes, output-only sources, bundled crossing events, no pause heartbeat/re-enable backlog, repeated scene cues; all numeric simulation sources can emit unit triggers on their original addresses")
    }
}
