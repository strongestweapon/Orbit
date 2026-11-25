import AppKit
import Network
import Darwin

final class DirectOSCInbox {
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
@main struct DirectOSCAddressChecks {
    static func pump(_ seconds: Double) { RunLoop.main.run(until:Date().addingTimeInterval(seconds)) }
    static func wait(_ message: String, _ predicate: () -> Bool) {
        let end=Date().addingTimeInterval(12)
        while !predicate() { precondition(Date()<end,message);pump(0.01) }
    }
    static func receive(_ connection: NWConnection, _ inbox: DirectOSCInbox) {
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
        let domain="studio.superless.Orbit.direct-address-test-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:domain)!,bundle=Bundle(path:CommandLine.arguments[1])!
        defer {defaults.removePersistentDomain(forName:domain)}
        func makeModel()->OrbitModel {OrbitModel(defaults:defaults,resources:bundle,controlOutput:ControlOutput())}
        let model=makeModel();defer {model.shutdownForTermination()}
        precondition(model.sensors.isEmpty)
        model.playing=false;model.port=String(freePort());model.startOSC();wait("listener") {model.oscRunning}
        let source=NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:UInt16(model.port)!)!,using:.udp)
        source.start(queue:DispatchQueue(label:"direct-address-test"));defer {source.cancel()}
        func send(_ address:String,_ value:Float) {source.send(content:OSCEncoder.floatMessage(address:address,value:value),completion:.contentProcessed({_ in}))}
        func address(_ key:String)->String {model.inputOSCAddress(key,sceneID:model.selectedSceneID,textured:model.usesTexture)}
        var tested=0
        for scene in model.scenes where !scene.testScene {
            model.selectedSceneID=scene.id
            for event in model.sceneTriggers {
                let path=address(event.id)
                precondition(path.hasPrefix("/orbit/scene/"+scene.id+"/events/"))
                precondition(model.inputOSCIssue(event.id,sceneID:scene.id,textured:false)==nil)
                precondition(model.route(for:event.id).input.sensorID==nil)
                send(path,0.49)
                wait("low trigger packet is received") {model.directOSCReceipts[event.id]?.packetCount==1}
                precondition(model.parameterEventCount(event.id)==0)
                let first=model.latestOSCInput(for:[event.id])!
                precondition(first.triggerCount==0 && first.activityLevel(at:first.receivedAt)==1)
                precondition(first.activityLevel(at:first.receivedAt.addingTimeInterval(0.5))>0)
                precondition(first.activityLevel(at:first.receivedAt.addingTimeInterval(1))==0)
                let cue=OSCEncoder.floatMessage(address:path,value:0.5)!
                source.send(content:OSCEncoder.immediateBundle([cue,cue,cue]),completion:.contentProcessed({_ in}))
                wait("three direct events \(scene.id) \(event.id)") {model.parameterEventCount(event.id)==3}
                let repeated=model.latestOSCInput(for:[event.id])!
                precondition(repeated.packetCount==4 && repeated.triggerCount==3 && repeated.receivedAt>=first.receivedAt)
                tested+=1
            }
            let path=address("speed"),spec=model.parameterSpec("speed")
            send(path,0.8);wait("normalized continuous") {abs(model.controlValue("speed")-spec.rawValue(normalized:0.8))<0.00001}
            let first=model.directOSCReceipts["speed"]!
            send(path,0.8)
            wait("identical continuous packet refreshes activity") {model.directOSCReceipts["speed"]?.packetCount==2}
            let repeated=model.latestOSCInput(for:["speed"])!
            precondition(repeated.value==first.value && repeated.receivedAt>first.receivedAt)
            send("/qa/unmapped",1);pump(0.03)
            precondition(model.directOSCReceipts["speed"]?.packetCount==2)
            let other=model.scenes.first {!$0.testScene && $0.id != scene.id}!
            let inactive=SceneOSCAddress.input(scene:other.id,parameter:model.triggers(for:other.id,textured:false)[0].id)
            let counts=model.sceneTriggers.map {model.parameterEventCount($0.id)}
            send(inactive,1);pump(0.03)
            precondition(model.selectedSceneID==scene.id && model.sceneTriggers.map {model.parameterEventCount($0.id)}==counts)
            model.setNormalizedParameterValue("speed",0.6)
            precondition(model.latestOSCInput(for:["speed"])==nil,"Manual sliders are not OSC packets")
            let event=model.sceneTriggers[0].id,received=model.directOSCReceipts[model.sceneTriggers[0].id]!
            model.triggerParameter(event)
            precondition(model.directOSCReceipts[event]?.packetCount==received.packetCount && model.directOSCReceipts[event]?.receivedAt==received.receivedAt,"Manual triggers do not renew OSC activity")
        }
        precondition(tested==25)
        model.selectedSceneID=PulseOrbitSimulation.sceneID
        precondition(model.latestOSCInput(for:model.parameterSpecs.map(\.id))==nil,"Scene changes clear receipt lights")
        let key=SceneTrigger.addLineID,original=address(key)
        // Direct input and a legacy sensor alias for the same address must not double-fire.
        model.sensors=[.init(name:"Shared alias",address:original)]
        model.setRoute(key) {$0.input.sensorID=model.sensors[0].id;$0.input.enabled=true}
        send(original,1);wait("no duplicate dispatch") {model.pulseLineCount==4}
        pump(0.08);precondition(model.pulseLineCount==4)
        model.setRoute(key) {$0.input.directOSCAddress="/qa/custom/line";$0.input.enabled=false}
        send(original,1);pump(0.05);precondition(model.pulseLineCount==4)
        send("/qa/custom/line",1);wait("custom address") {model.pulseLineCount==5}
        model.setRoute(key) {$0.input.directOSCEnabled=false}
        send("/qa/custom/line",1);pump(0.05);precondition(model.pulseLineCount==5)
        precondition(model.latestOSCInput(for:[key])==nil,"Disabled input must not light up")
        model.setRoute(key) {$0.input.directOSCEnabled=true;$0.input.directOSCAddress="/orbit/play"}
        precondition(model.inputOSCIssue(key,sceneID:model.selectedSceneID,textured:false) != nil)
        let sharedEvent=model.sceneTriggers[0].id,sharedAddress=address(model.sceneTriggers[0].id)
        model.setRoute(key) {$0.input.directOSCAddress=sharedAddress}
        precondition(model.inputOSCIssue(key,sceneID:model.selectedSceneID,textured:false)==nil)
        let beforeShared=model.parameterEventCount(sharedEvent)
        send(sharedAddress,1)
        wait("one input controls both events") {model.pulseLineCount==6 && model.parameterEventCount(sharedEvent)==beforeShared+1}
        model.setRoute(key) {$0.input.directOSCAddress="/qa/custom/line"}
        // An old sensor connection becomes one direct address; no competing hidden input.
        model.sensors=[.init(name:"Sensor",address:"/qa/sensor")]
        model.setRoute("brightness") {$0.input.enabled=true;$0.input.sensorID=model.sensors[0].id;$0.input.smoothingSeconds=0}
        precondition(address("brightness")=="/qa/sensor" && model.route(for:"brightness").input.sensorID==nil && !model.route(for:"brightness").input.enabled)
        send("/qa/sensor",0.2);wait("migrated address") {abs(model.normalizedParameterValue("brightness")-0.2)<0.00001}
        send(address("brightness"),0.8);wait("direct update") {abs(model.normalizedParameterValue("brightness")-0.8)<0.00001}
        send("/qa/sensor",0.3);wait("next direct update") {abs(model.normalizedParameterValue("brightness")-0.3)<0.00001}
        // Source modes have separate addresses and must never affect each other's settings.
        let other=model.scenes.first {!$0.testScene && $0.texture != nil}!
        model.selectedSceneID=other.id;model.setRenderStyle(1)
        let originalSource=address("brightness")
        precondition(originalSource.contains("/original/parameters/"))
        send(originalSource,0.65);wait("original source") {abs(model.normalizedParameterValue("brightness")-0.65)<0.00001}
        model.setRenderStyle(0)
        let old=model.baseParameterValue("brightness")
        send(originalSource,0.1);pump(0.05);precondition(model.baseParameterValue("brightness")==old)
        precondition(model.latestOSCInput(for:["brightness"])==nil,"Other source modes must not light up")
        model.save()
        let restored=makeModel();defer {restored.shutdownForTermination()}
        precondition(restored.inputOSCAddress(key,sceneID:PulseOrbitSimulation.sceneID,textured:false)=="/qa/custom/line")
        precondition(restored.route(for:key,sceneID:PulseOrbitSimulation.sceneID,textured:false).input.receivesDirectOSC)
        precondition(restored.directOSCReceipts.isEmpty)
        precondition(restored.mappingRows.filter {$0.spec?.outputOnly==false}.allSatisfy {$0.address.hasPrefix("/")})
        precondition(restored.sensors.isEmpty)
        // Upgrade persisted legacy inputs in both source modes, retaining OSC argument and a raw backup.
        var stored=try JSONDecoder().decode(StoredSettings.self,from:defaults.data(forKey:"OrbitSettings.v1")!)
        let legacySensor=SensorInput(name:"Old installation label",address:"/qa/legacy",argument:2)
        stored.sensors=[legacySensor]
        var legacyRoute=ParameterRoute.defaults(scene:other.id,parameter:"brightness")
        legacyRoute.input.enabled=true;legacyRoute.input.sensorID=legacySensor.id
        stored.scenes[other.id]?.parameterRoutes=["brightness":legacyRoute]
        stored.scenes[other.id]?.textureParameterRoutes=["brightness":legacyRoute]
        let legacyData=try JSONEncoder().encode(stored)
        defaults.set(legacyData,forKey:"OrbitSettings.v1")
        defaults.removeObject(forKey:"OrbitSettings.beforeAddressOnly.v1")
        let migrated=makeModel();defer {migrated.shutdownForTermination()}
        precondition(migrated.sensors.isEmpty)
        precondition(defaults.data(forKey:"OrbitSettings.beforeAddressOnly.v1")==legacyData)
        migrated.selectedSceneID=other.id
        for textured in [false,true] {
            let input=migrated.route(for:"brightness",sceneID:other.id,textured:textured).input
            precondition(input.directOSCAddress=="/qa/legacy" && input.oscArgument==2)
            precondition(input.sensorID==nil && !input.enabled && input.receivesDirectOSC)
            migrated.setRenderStyle(textured ? 1:0)
            migrated.receiveOSC(address:"/qa/legacy",values:[0.1,0.2,0.8])
            precondition(abs(migrated.normalizedParameterValue("brightness")-0.8)<0.00001)
        }
        migrated.save()
        let upgraded=try JSONDecoder().decode(StoredSettings.self,from:defaults.data(forKey:"OrbitSettings.v1")!)
        precondition(upgraded.sensors.isEmpty)
        precondition(OSCNetworkAddress.current().allSatisfy {!$0.address.hasPrefix("127.") && !$0.interface.isEmpty})
        model.stopOSC()
        precondition(model.latestOSCInput(for:model.parameterSpecs.map(\.id))==nil)
        print("PASS: packet activity for all 25 triggers and continuous values; identical packets refresh; timed fade; manual/unknown/disabled/inactive/source isolation; reset and stop clear indicators")
        print("PASS: 25 default event addresses over UDP; repeated cues; normalized continuous values; inactive/source isolation; custom/disabled/global collision addresses; same-address fanout; legacy address+argument migration; backup and persistence; local interface listing")
    }
}
