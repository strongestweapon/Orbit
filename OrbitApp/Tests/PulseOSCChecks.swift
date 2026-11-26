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

        precondition(controls.count==5 && model.sceneTriggers.count==4)
        precondition(model.sensors.isEmpty)
        for control in controls {
            model.setRoute(control.id) {
                $0.input.directOSCAddress="/qa/in/"+control.id
                $0.output.enabled=true;$0.output.configured=true
                $0.output.address="/qa/out/"+control.id;$0.output.minimum=0;$0.output.maximum=1
            }
        }
        model.port=String(freePort());model.startOSC();wait("receiver") {model.oscRunning}
        model.controlOutputEnabled=true
        let source=NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:UInt16(model.port)!)!,using:.udp)
        source.start(queue:queue);defer {source.cancel()}
        func send(_ address:String,_ value:Float) {source.send(content:OSCEncoder.floatMessage(address:address,value:value),completion:.contentProcessed({_ in}))}
        func count(_ address:String)->Int {inbox.snapshot().0.flatMap {OSCDecoder.decode($0)}.filter {$0.address==address}.count}
        for control in controls {send("/qa/in/"+control.id,0.62)}
        wait("five real Float inputs") {controls.allSatisfy {abs(model.normalizedParameterValue($0.id)-0.62)<0.00001}}
        wait("five real Float outputs") {controls.allSatisfy {abs((inbox.latest("/qa/out/"+$0.id) ?? -1)-0.62)<0.00001}}
        send("/qa/in/attractorPosition",0.81)
        wait("OSC moves attractor") {abs(model.normalizedParameterValue("attractorPosition")-0.81)<0.00001}
        precondition(abs(Double(model.uniforms(width:1920,height:1080,view:1)[20])-0.81)<0.00001)
        wait("OSC reports attractor position") {abs((inbox.latest("/qa/out/attractorPosition") ?? -1)-0.81)<0.00001}
        model.playing=true
        let resting=Array(model.uniforms(width:1920,height:1080,view:1)[24..<36])
        send("/qa/in/directionDrive",1);send("/qa/in/attraction",0.9)
        wait("continuous inputs while playing") {model.normalizedParameterValue("directionDrive")==1 && abs(model.normalizedParameterValue("attraction")-0.9)<0.00001}
        for _ in 0..<15 {
            pump(0.02)
            let current=model.uniforms(width:1920,height:1080,view:1)
            precondition(current[36..<48].allSatisfy {abs($0)<0.42},"Continuous OSC inputs must stay in the bounded base flow")
        }
        precondition(model.pulseAccentCount==0 && Array(model.uniforms(width:1920,height:1080,view:1)[24..<36]) != resting)
        model.playing=false
        var integer=OSCEncoder.floatMessage(address:"/qa/in/inertia",value:0.2)!
        let tag=integer.range(of:Data([44,102,0,0]))!;integer[tag.lowerBound+1]=105
        source.send(content:integer,completion:.contentProcessed({_ in}));pump(0.1)
        precondition(abs(model.normalizedParameterValue("inertia")-0.62)<0.00001)
        for control in controls {model.setRoute(control.id) {$0.output.enabled=false}}
        for event in model.sceneTriggers {
            model.setRoute(event.id) {$0.output.enabled=true;$0.output.address="/qa/event/"+event.id}
        }
        for key in [PulseOrbitOutputs.accentAngle,PulseOrbitOutputs.accentStrength] {
            model.setRoute(key) {$0.input.enabled=true;$0.output.enabled=true;$0.output.address="/qa/meta/"+key}
            precondition(!model.route(for:key).input.enabled)
        }
        let before=model.parameterValues
        let key=SceneTrigger.departureID,address=model.inputOSCAddress(key,sceneID:PulseOrbitSimulation.sceneID,textured:false)
        precondition(!address.isEmpty)
        model.restartPlayback();model.playing=false
        send(address,0.49);pump(0.1);precondition(model.parameterEventCount(key)==0)
        for _ in 0..<20 {send(address,1)}
        wait("all repeated inputs counted") {model.parameterEventCount(key)==20}
        wait("every rapid event emits") {count("/qa/event/"+key)==20}
        precondition(model.pulseAccentCount==20 && model.parameterValues==before)
        let packet=inbox.snapshot().0.first {OSCDecoder.decode($0).contains {$0.address=="/qa/event/"+key}}!
        let fields=OSCDecoder.decode(packet)
        precondition(fields.map(\.address)==["/qa/meta/accentAngle","/qa/meta/accentStrength","/qa/event/"+key])
        precondition(fields.last!.values==[1] && fields.allSatisfy {$0.values.count==1 && (0...1).contains($0.values[0])})
        precondition(abs(fields[0].values[0]-0.81)<0.00001)
        for event in model.sceneTriggers where event.id != key {model.triggerParameter(event.id)}
        precondition(model.pulseAccentCount==23 && model.pulseLineCount==4)
        for _ in 0..<7 {model.triggerParameter(SceneTrigger.addLineID)}
        precondition(model.pulseLineCount==3 && model.parameterEventCount(SceneTrigger.addLineID)==8)
        wait("every rapid line command emits") {count("/qa/event/"+SceneTrigger.addLineID)==8}
        precondition(model.pulseAccentCount==24)
        // No queue: quiet time must not repeat prior commands.
        pump(0.2);precondition(count("/qa/event/"+key)==20)
        model.triggerParameter(SceneTrigger.completionID)
        wait("immediate repeated completion cue") {count("/qa/event/"+SceneTrigger.completionID)==2}
        model.testControlOutput(SceneTrigger.completionID)
        wait("explicit send test") {count("/qa/event/"+SceneTrigger.completionID)==3}
        // Metadata can be enabled independently without requiring the associated cue checkbox.
        for event in model.sceneTriggers {model.setRoute(event.id) {$0.output.enabled=false}}
        model.restartPlayback();model.playing=false
        let metaBefore=count("/qa/meta/accentAngle"),cueBefore=count("/qa/event/"+key)
        model.triggerParameter(key)
        wait("independent metadata output") {count("/qa/meta/accentAngle")==metaBefore+1}
        precondition(count("/qa/event/"+key)==cueBefore)
        // A continuous value can still send unit cues on the same address.
        let input="/qa/in/inertia",out="/qa/out/inertia"
        model.setRoute("inertia") {$0.output.enabled=true;$0.output.mode = .trigger}
        precondition(model.route(for:"inertia").output.address==out)
        model.restartPlayback();model.playing=false
        let prior=count(out)
        send(input,0);send(input,0)
        wait("continuous Float zero is valid") {model.normalizedParameterValue("inertia")==0}
        wait("continuous input to unit cue") {count(out)==prior+2}
        precondition(inbox.latest(out)==1)
        pump(0.1);precondition(count(out)==prior+2)
        // Preserve all five routes; retired controls do not return to the live catalog.
        model.save()
        let restored=OrbitModel(defaults:defaults,resources:bundle,controlOutput:ControlOutput())
        defer {restored.shutdownForTermination()}
        restored.selectedSceneID=PulseOrbitSimulation.sceneID;restored.playing=false
        precondition(restored.shaderParameters.count==5 && restored.sceneTriggers.count==4)
        for control in controls {precondition(restored.route(for:control.id).output.address=="/qa/out/"+control.id)}
        precondition(restored.route(for:"inertia").output.behavior == .trigger)
        precondition(restored.pulseLineCount==3 && restored.pulseAccentCount==0)
        let cue=model.globalOSC.first {$0.sceneID==PulseOrbitSimulation.sceneID}!
        for expected in 1...3 {
            send(cue.address,1);wait("repeated scene cue") {model.globalReceipts[cue.id]?.triggerCount==expected}
            precondition(model.pulseLineCount==3 && model.pulseAccentCount==0)
        }
        print("PASS: five real UDP control inputs/outputs, integer rejection, four causal commands, repeated inputs counted, 24-voice bound, 3–10 topology, event metadata bundle, every rapid command and repeated continuous packet emits, no backlog, explicit test, continuous-to-trigger same address, persistence and scene reset")
    }
}
