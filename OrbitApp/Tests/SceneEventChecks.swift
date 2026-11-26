import AppKit
import Network
import Darwin

final class EventInbox {
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
@main struct SceneEventChecks {
    static func pump(_ seconds: Double) { RunLoop.main.run(until:Date().addingTimeInterval(seconds)) }
    static func wait(_ message: String, _ predicate: () -> Bool) {
        let end=Date().addingTimeInterval(12)
        while !predicate() { precondition(Date()<end,message);pump(0.01) }
    }
    static func receive(_ connection: NWConnection, _ inbox: EventInbox) {
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
        let inbox=EventInbox(),queue=DispatchQueue(label:"orbit-distinct-events-loopback")
        let listener=try NWListener(using:.udp,on:.any)
        listener.stateUpdateHandler={state in if case .ready=state,let port=listener.port {inbox.ready(port.rawValue)}}
        listener.newConnectionHandler={connection in inbox.hold(connection);connection.start(queue:queue);receive(connection,inbox)}
        listener.start(queue:queue);defer {listener.cancel()}
        wait("listener") {inbox.snapshot().1 != nil}
        let domain="studio.superless.Orbit.distinct-events-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:domain)!
        // Use one isolated suite for both initial load and reload, never the operator's preferences.
        defer {defaults.removePersistentDomain(forName:domain)}
        let bundle=Bundle(path:CommandLine.arguments[1])!
        let model=OrbitModel(defaults:defaults,resources:bundle,controlOutput:ControlOutput())
        defer {model.shutdownForTermination()}
        model.playing=false
        model.setOSCOutputDestination(.init(host:"127.0.0.1",port:Int(inbox.snapshot().1!)))
        precondition(model.sensors.isEmpty)
        model.port=String(freePort());model.startOSC();wait("OSC receiver") {model.oscRunning}
        let source=NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:UInt16(model.port)!)!,using:.udp)
        source.start(queue:queue);defer {source.cancel()}
        func send(_ value:Float,_ address:String="/qa/login") {source.send(content:OSCEncoder.floatMessage(address:address,value:value),completion:.contentProcessed({_ in}))}
        func count(_ address:String)->Int {inbox.snapshot().0.flatMap {OSCDecoder.decode($0)}.filter {$0.address==address}.count}
        func output(_ key:String,_ address:String) {
            model.setRoute(key) {$0.output.enabled=true;$0.output.transport = .osc;$0.output.address=address;$0.output.minimum=0;$0.output.maximum=1}
        }
        let scenes=model.scenes.filter {!$0.testScene};precondition(scenes.count==8)
        var tested=0
        for scene in scenes where scene.id != PulseOrbitSimulation.sceneID {
            model.selectedSceneID=scene.id
            precondition(model.sceneTriggers.count==(scene.id==PulseOrbitSimulation.sceneID ? 4 : 3))
            for event in model.sceneTriggers where event.id != SceneTrigger.addLineID {
                precondition(model.parameterSpec(event.id).isTrigger && model.parameterSpec(event.id).eventOutput)
                precondition(scene.parameters.allSatisfy {$0.id != event.id})
                let effectKeys=Set(event.offsets.keys).union(event.targets.keys).union(event.reverse)
                precondition(effectKeys.allSatisfy {key in model.parameterSpecs.contains {$0.id==key && !$0.isTrigger}},"Unknown renderer target")
                let key=event.id,address="/qa/event/"+scene.id+"/"+key
                model.setRoute(key) {$0.input.event = .init(threshold:.init(),attack:0,hold:0.08,release:0.04)}
                output(key,address)
                model.controlOutputEnabled=true;pump(0.04)
                let settingsBefore=model.activeSettings.values,valuesBefore=model.parameterValues,routesBefore=model.activeRoutes
                let uniformsBefore=model.uniforms(width:1920,height:1080,view:1)
                model.triggerParameter(key);model.triggerParameter(key)
                precondition(model.parameterEventCount(key)==2)
                let uniformsDuring=model.uniforms(width:1920,height:1080,view:1)
                precondition(uniformsBefore != uniformsDuring,"Event did not affect render uniforms: \(scene.id) \(key)")
                precondition(model.parameterValues==valuesBefore && model.activeSettings.values==settingsBefore && model.activeRoutes==routesBefore,"Trigger mutated continuous controls")
                wait("two one-shot cues") {count(address)==2}
                wait("visual event ends") {(model.triggerLevels()[key] ?? 0)==0}
                precondition(model.uniforms(width:1920,height:1080,view:1)==uniformsBefore,"Render did not return to baseline")
                precondition(count(address)==2)
                tested+=1
            }
            // Identical OSC events are commands, not a sustained slider value.
            let key=model.sceneTriggers[0].id,address="/qa/event/"+scene.id+"/"+key
            model.setRoute(key) {$0.input.directOSCAddress="/qa/login"}
            send(0.49);pump(0.03);precondition(count(address)==2)
            let cue=OSCEncoder.floatMessage(address:"/qa/login",value:1)!
            source.send(content:OSCEncoder.immediateBundle([cue,cue,cue]),completion:.contentProcessed({_ in}))
            wait("three identical OSC triggers") {count(address)==5 && model.parameterEventCount(key)==5}
            wait("return") {(model.triggerLevels()[key] ?? 0)==0}
            model.selectedSceneID=model.scenes.first {$0.testScene}!.id
            model.selectedSceneID=scene.id;pump(0.04)
            precondition(count(address)==5 && model.parameterEventCount(key)==0,"Cached high cue replayed")
        }
        precondition(tested==21)
        model.selectedSceneID=PulseOrbitSimulation.sceneID;model.playing=false
        // The add-line command changes topology, not a continuous parameter or temporary envelope.
        let addLine=SceneTrigger.addLineID,lineAddress="/qa/event/lines"
        model.setRoute(addLine) {$0.input.directOSCAddress="/qa/login"}
        output(addLine,lineAddress)
        let continuousBefore=model.parameterValues
        precondition(model.pulseLineCount==3 && model.pulseLineLimit==10)
        for expected in 4...8 {
            model.triggerParameter(addLine)
            precondition(model.pulseLineCount==expected)
            for view in [Float(0),1,2] {precondition(model.uniforms(width:3840,height:2160,view:view)[PulseOrbitSimulation.lineCountOffset]==Float(expected))}
        }
        wait("five manual line cues") {count(lineAddress)==5}
        pump(1);precondition(model.pulseLineCount==8,"Added lines must survive the event envelope")
        send(0.49);pump(0.05);precondition(model.pulseLineCount==8)
        let lineCue=OSCEncoder.floatMessage(address:"/qa/login",value:1)!
        source.send(content:OSCEncoder.immediateBundle([lineCue,lineCue,lineCue]),completion:.contentProcessed({_ in}))
        wait("three line events") {model.pulseLineCount==3 && count(lineAddress)==8}
        precondition(model.parameterValues==continuousBefore,"Line command changed sliders")
        model.setRoute(addLine) {$0.input.lineLimit=4}
        send(1);wait("add line four") {model.pulseLineCount==4 && count(lineAddress)==9}
        send(1);wait("wrap to three") {model.pulseLineCount==3 && count(lineAddress)==10}
        model.triggerParameter(addLine);precondition(model.pulseLineCount==4)
        wait("manual cue") {count(lineAddress)==11}
        model.restartPlayback();precondition(model.pulseLineCount==3)
        model.setRoute(addLine) {$0.input.directOSCEnabled=false}

        model.selectedSceneID="08_golden_drift";model.playing=false
        let key=model.sceneTriggers[0].id,address="/qa/event/"+model.selectedSceneID+"/"+key
        model.setInputBehavior(key,.threshold)
        let before=count(address)
        for (value,expected) in [(Float(0.1),0),(0.5,1),(1,2),(0.49,2),(0.51,3),(0.44,3),(0.5,4)] {
            send(value);pump(0.06);precondition(count(address)==before+expected)
        }
        // A continuous OSC input remains independent while a separate event watches its threshold.
        let valueKey=model.shaderParameters.first!.id
        model.setRoute(valueKey) {
            $0.input.directOSCAddress="/qa/value"
            $0.input.mode = .event;$0.output.mode = .event // Rejected: these are not trigger IDs.
        }
        precondition(model.route(for:valueKey).input.behavior == .continuous && model.route(for:valueKey).output.behavior == .continuous)
        output(valueKey,"/qa/continuous")
        model.setRoute(key) {$0.input.sourceParameter=valueKey;$0.input.enabled=true;$0.input.mode = .threshold}
        send(0.1,"/qa/value");pump(0.07)
        let beforeSource=count(address)
        send(0.8,"/qa/value");wait("continuous source crossing") {count(address)==beforeSource+1}
        precondition(abs(model.normalizedParameterValue(valueKey)-0.8)<0.00001)
        wait("continuous output independent") {abs((inbox.latest("/qa/continuous") ?? -1)-0.8)<0.00001}
        let held=model.parameterValues
        model.triggerParameter(key);wait("button event") {count(address)==beforeSource+2}
        precondition(model.parameterValues==held && abs(model.normalizedParameterValue(valueKey)-0.8)<0.00001)
        let quiet=count(address);pump(2.2);precondition(count(address)==quiet,"Trigger heartbeat")
        model.controlOutputEnabled=false;send(0.1,"/qa/value");pump(0.06);send(0.8,"/qa/value");pump(0.06)
        model.controlOutputEnabled=true;pump(0.08);precondition(count(address)==quiet,"Re-enable backlog")
        // Continuous parameters cannot be invoked as event commands.
        model.triggerParameter(valueKey);precondition(model.parameterEventCount(valueKey)==0)
        model.save()
        let restored=OrbitModel(defaults:defaults,resources:bundle,controlOutput:ControlOutput())
        defer {restored.shutdownForTermination()}
        for scene in scenes where scene.id != PulseOrbitSimulation.sceneID {
            restored.selectedSceneID=scene.id
            for event in restored.sceneTriggers {
                precondition(restored.route(for:event.id).output.enabled)
                precondition(restored.parameterEventCount(event.id)==0)
            }
        }
        restored.selectedSceneID=PulseOrbitSimulation.sceneID
        precondition(restored.pulseLineCount==3 && restored.pulseLineLimit==4,"Persist maximum, never replay accumulated line events")
        let events=inbox.snapshot().0.flatMap {OSCDecoder.decode($0)}.filter {$0.address.hasPrefix("/qa/event/")}
        precondition(events.allSatisfy {$0.values==[1]})
        print("PASS: 21 transient triggers + persistent add-line command, 3–10 and custom-limit cycles, shared topology in every output, all 8 scenes, visual uniforms change and return, continuous controls/settings/routes unchanged, repeated OSC cues, threshold hysteresis, independent continuous OSC output, no heartbeat/backlog, persistence")
    }
}
