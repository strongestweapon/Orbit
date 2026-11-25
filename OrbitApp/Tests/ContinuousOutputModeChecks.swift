import AppKit
import Network
import Darwin

private final class ValueCueInbox {
    let listener: NWListener
    private let lock=NSLock()
    private var messages: [(String,Double)] = []
    private var connections: [NWConnection] = []
    private var assignedPort: UInt16?
    init() throws {
        listener=try NWListener(using:.udp,on:.any)
        let queue=DispatchQueue(label:"orbit-value-cue-check")
        listener.stateUpdateHandler={ [weak self] state in
            guard let self,case .ready=state,let port=self.listener.port else {return}
            self.lock.lock();self.assignedPort=port.rawValue;self.lock.unlock()
        }
        listener.newConnectionHandler={ [weak self] connection in
            guard let self else {return}
            self.lock.lock();self.connections.append(connection);self.lock.unlock()
            connection.start(queue:queue);self.receive(connection)
        }
        listener.start(queue:queue)
    }
    var port: UInt16? {lock.lock();defer {lock.unlock()};return assignedPort}
    func values(_ address:String)->[Double] {
        lock.lock();defer {lock.unlock()};return messages.filter {$0.0==address}.map(\.1)
    }
    private func receive(_ connection:NWConnection) {
        connection.receiveMessage { [weak self] data,_,_,error in
            guard let self else {return}
            if let data {
                let received=OSCDecoder.decode(data).compactMap {message in message.values.first.map {(message.address,$0)} }
                self.lock.lock();self.messages.append(contentsOf:received);self.lock.unlock()
            }
            if error==nil {self.receive(connection)}
        }
    }
    func stop() {listener.cancel();lock.lock();let held=connections;lock.unlock();held.forEach {$0.cancel()}}
}

/// Actual OSC packets exercise every continuous control, in both source modes.
@main struct ContinuousOutputModeChecks {
    static func pump(_ seconds:Double) {RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
    static func wait(_ message:String,_ predicate:()->Bool) {
        let end=Date().addingTimeInterval(15)
        while !predicate() {precondition(Date()<end,message);pump(0.01)}
    }
    static func freePort()->UInt16 {
        let fd=socket(AF_INET,SOCK_DGRAM,0);precondition(fd>=0);defer {Darwin.close(fd)}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET)
        address.sin_addr.s_addr=inet_addr("127.0.0.1")
        let bound=withUnsafePointer(to:&address) {ptr in ptr.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        precondition(bound==0)
        var length=socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to:&address) {ptr in _=ptr.withMemoryRebound(to:sockaddr.self,capacity:1) {getsockname(fd,$0,&length)}}
        return UInt16(bigEndian:address.sin_port)
    }
    static func main() throws {
        let inbox=try ValueCueInbox();defer {inbox.stop()};wait("output listener") {inbox.port != nil}
        let domain="studio.superless.Orbit.value-cue-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:domain)!,bundle=Bundle(path:CommandLine.arguments[1])!
        defer {defaults.removePersistentDomain(forName:domain)}
        func makeModel()->OrbitModel {OrbitModel(defaults:defaults,resources:bundle,controlOutput:ControlOutput())}
        let model=makeModel();defer {model.shutdownForTermination()}
        model.playing=false;model.port=String(freePort());model.startOSC();wait("input listener") {model.oscRunning}
        model.setOSCOutputDestination(.init(host:"127.0.0.1",port:Int(inbox.port!)))
        let sender=NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:UInt16(model.port)!)!,using:.udp)
        sender.start(queue:DispatchQueue(label:"orbit-value-cue-send"));defer {sender.cancel()}
        func send(_ path:String,_ value:Float) {sender.send(content:OSCEncoder.floatMessage(address:path,value:value),completion:.contentProcessed({_ in}))}
        func input(_ key:String)->String {model.inputOSCAddress(key,sceneID:model.selectedSceneID,textured:model.usesTexture)}
        var checked=0
        for scene in model.scenes where !scene.testScene {
            for textured in scene.texture == nil ? [false] : [false,true] {
                model.controlOutputEnabled=false;model.selectedSceneID=scene.id;model.setRenderStyle(textured ? 1:0)
                let specs=model.parameterSpecs.filter {!$0.outputOnly && !$0.isTrigger}
                for spec in specs {
                    model.setRoute(spec.id) {$0.output.enabled=true;$0.output.mode = .trigger;$0.output.minimum=0.2;$0.output.maximum=0.8}
                    precondition(model.route(for:spec.id).output.behavior == .trigger)
                }
                let priorCounts=Dictionary(uniqueKeysWithValues:specs.map {($0.id,inbox.values(model.route(for:$0.id).output.address).count)})
                model.controlOutputEnabled=true
                let packets=specs.flatMap {spec in [Float(0.2),0.2,0,0.75].map {OSCEncoder.floatMessage(address:input(spec.id),value:$0)!}}
                sender.send(content:OSCEncoder.immediateBundle(packets),completion:.contentProcessed({_ in}))
                wait("every packet has one trigger \(scene.id) \(textured)") {
                    specs.allSatisfy {inbox.values(model.route(for:$0.id).output.address).count==priorCounts[$0.id]!+4}
                }
                for spec in specs {
                    let route=model.route(for:spec.id).output
                    precondition(inbox.values(route.address).suffix(4)==[1,1,1,1])
                    precondition(abs(model.controlValue(spec.id)-spec.rawValue(normalized:0.75))<0.00001)
                    precondition(route.minimum==0.2 && route.maximum==0.8)
                    let row=model.mappingRows.first {$0.sceneID==scene.id && $0.textured==textured && $0.spec?.id==spec.id}!
                    precondition(row.outputRangeLabel?.contains("입력마다 트리거")==true && !row.isEvent)
                }
                checked+=specs.count
                // A saved trigger output stays on the continuous control; migration must not split it.
                model.save()
                let restored=makeModel();restored.selectedSceneID=scene.id;restored.setRenderStyle(textured ? 1:0)
                for spec in specs {
                    let a=model.route(for:spec.id).output,b=restored.route(for:spec.id).output
                    precondition(a==b && b.behavior == .trigger)
                    precondition(!restored.sceneTriggers.contains {$0.id=="trigger.parameter."+spec.id})
                }
                restored.shutdownForTermination()
            }
        }
        // In this scene, changing output mode must retain the exact address and scale.
        let key="brightness",path=input(key),output=model.route(for:key).output.address
        let initial=inbox.values(output).count
        pump(2.2);precondition(inbox.values(output).count==initial,"No trigger heartbeat")
        model.setRoute(key) {$0.output.mode = .continuous}
        precondition(model.route(for:key).output.address==output)
        send(path,0.25)
        wait("continuous output restores original scaling") {abs((inbox.values(output).last ?? -1)-0.35)<0.00001}
        model.setRoute(key) {$0.output.mode = .trigger}
        pump(0.1);let before=inbox.values(output).count
        pump(2.2);precondition(inbox.values(output).count==before,"Mode switch must not fire")
        send(path,0.25);send(path,0.25)
        wait("same-valued input after mode change") {inbox.values(output).count==before+2}
        precondition(inbox.values(output).suffix(2)==[1,1])
        model.setNormalizedParameterValue(key,0.4)
        wait("manual changed value") {inbox.values(output).count==before+3}
        model.setNormalizedParameterValue(key,0.4);pump(0.1)
        precondition(inbox.values(output).count==before+3,"Same manual value is not a new input")
        model.setRoute(key) {$0.output.enabled=false}
        send(path,0.1);pump(0.1);precondition(inbox.values(output).count==before+3)
        model.testControlOutput(key)
        wait("manual test sends one cue without enabling route") {inbox.values(output).count==before+4}
        precondition(!model.route(for:key).output.enabled && inbox.values(output).last==1)
        model.setRoute(key) {$0.output.enabled=true;$0.input.directOSCEnabled=false}
        send(path,0.7);pump(0.1);precondition(inbox.values(output).count==before+4)
        model.setRoute(key) {$0.input.directOSCEnabled=true}
        send(path,.nan);pump(0.1);precondition(inbox.values(output).count==before+4)
        model.controlOutputEnabled=false;send(path,0.2);pump(0.1)
        model.controlOutputEnabled=true;pump(0.1)
        precondition(inbox.values(output).count==before+4,"Do not replay missed packets")
        print("PASS: \(checked) continuous controls over real UDP: one Float 1.0 per input including repeated and zero values; original/real-time sources; saved modes and addresses; value scaling restored; no idle or mode-change cues; manual changes/tests; disabled/invalid inputs and no replay")
    }
}
