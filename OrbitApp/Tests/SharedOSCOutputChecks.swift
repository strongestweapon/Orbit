import AppKit
import Network

final class SharedOSCInbox {
    private let lock=NSLock()
    private var packets:[Data]=[]
    private var connections:[NWConnection]=[]
    private var assignedPort:UInt16?
    let listener:NWListener
    private let queue=DispatchQueue(label:"orbit-shared-osc-listener-"+UUID().uuidString)
    init() throws {
        listener=try NWListener(using:.udp,on:.any)
        listener.stateUpdateHandler={ [weak self] state in
            guard let self else {return}
            if case .ready=state,let port=self.listener.port {self.lock.lock();self.assignedPort=port.rawValue;self.lock.unlock()}
        }
        listener.newConnectionHandler={ [weak self] connection in
            guard let self else {return}
            self.lock.lock();self.connections.append(connection);self.lock.unlock()
            connection.start(queue:self.queue);self.receive(connection)
        }
        listener.start(queue:queue)
    }
    var port:Int? {lock.lock();defer {lock.unlock()};return assignedPort.map(Int.init)}
    func count(_ address:String) -> Int {
        lock.lock();let snapshot=packets;lock.unlock()
        return snapshot.flatMap {OSCDecoder.decode($0)}.filter {$0.address==address}.count
    }
    func latest(_ address:String) -> Double? {
        lock.lock();let snapshot=packets;lock.unlock()
        return snapshot.flatMap {OSCDecoder.decode($0)}.last {$0.address==address}?.values.first
    }
    private func receive(_ connection:NWConnection) {
        connection.receiveMessage { [weak self] data,_,_,error in
            guard let self else {return}
            if let data {self.lock.lock();self.packets.append(data);self.lock.unlock()}
            if error == nil {self.receive(connection)}
        }
    }
    func stop() {listener.cancel();connections.forEach {$0.cancel()}}
}

@main struct SharedOSCOutputChecks {
    static func pump(_ seconds:Double) {RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
    static func wait(_ message:String,_ predicate:()->Bool) {
        let end=Date().addingTimeInterval(10)
        while !predicate() {precondition(Date()<end,message);pump(0.01)}
    }
    static func main() throws {
        let a=try SharedOSCInbox(),b=try SharedOSCInbox();defer {a.stop();b.stop()}
        wait("UDP listeners") {a.port != nil && b.port != nil}
        let domain="studio.superless.Orbit.shared-osc-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:domain)!,resources=Bundle(path:CommandLine.arguments[1])!
        defer {defaults.removePersistentDomain(forName:domain)}
        func makeModel() -> OrbitModel {OrbitModel(defaults:defaults,resources:resources,controlOutput:ControlOutput())}
        let model=makeModel();defer {model.shutdownForTermination()}
        model.selectedSceneID=PulseOrbitSimulation.sceneID;model.playing=false
        let scene=model.selectedSceneID,key=SceneTrigger.addLineID
        let destinationA=OSCOutputDestination(host:"127.0.0.1",port:a.port!)
        let destinationB=OSCOutputDestination(host:"127.0.0.1",port:b.port!)
        precondition(model.setOSCOutputDestination(destinationA))
        precondition(!model.mappingRows.contains {$0.globalID==nil && $0.configured},"Changing the common destination must not invent connections")
        model.setRoute("brightness") {
            $0.output.enabled=true;$0.output.transport = .osc;$0.output.maximum=1;$0.output.address="/qa/continuous"
            $0.output.host="127.0.0.2";$0.output.port=b.port! // Obsolete per-control endpoint must never win.
        }
        model.setRoute(key) {
            $0.input.directOSCAddress="/qa/event_in"
            $0.output.enabled=true;$0.output.transport = .osc;$0.output.address="/qa/event";$0.output.port=b.port!
        }
        model.setNormalizedParameterValue("brightness",0.4)
        model.controlOutputEnabled=true
        wait("continuous output to common A") {abs((a.latest("/qa/continuous") ?? -1)-0.4)<0.0001}
        for _ in 0..<3 {model.receiveOSC(address:"/qa/event_in",values:[1])}
        wait("three repeated events to common A") {a.count("/qa/event")==3}
        wait("overview reads actual send receipt") {model.controlDelivery(for:key,sceneID:scene,textured:false)?.value == 1}
        precondition(model.controlDelivery(for:key,sceneID:scene,textured:true)==nil,"Original and generated send receipts must be separate")
        precondition(model.controlDelivery(for:key,sceneID:"01_chroma_flow",textured:false)==nil,"Other scenes must not inherit the live send status")
        precondition(b.count("/qa/event")==0 && b.count("/qa/continuous")==0)
        let eventCount=model.parameterEventCount(key),lineCount=model.pulseLineCount
        precondition(model.setOSCOutputDestination(destinationB))
        precondition(model.controlDelivery(for:key,sceneID:scene,textured:false)==nil,"Old destination receipts must not appear as current sends")
        wait("continuous output moved to B") {abs((b.latest("/qa/continuous") ?? -1)-0.4)<0.0001}
        pump(0.2)
        let oldContinuous=a.count("/qa/continuous"),oldEvents=a.count("/qa/event")
        precondition(model.parameterEventCount(key)==eventCount && model.pulseLineCount==lineCount)
        precondition(b.count("/qa/event")==0,"Destination change replayed old events")
        for _ in 0..<2 {model.receiveOSC(address:"/qa/event_in",values:[1])}
        wait("new events to common B") {b.count("/qa/event")==2}
        model.setNormalizedParameterValue("brightness",0.65)
        wait("new continuous value to B") {abs((b.latest("/qa/continuous") ?? -1)-0.65)<0.0001}
        precondition(a.count("/qa/event")==oldEvents && a.count("/qa/continuous")==oldContinuous)

        // The same common endpoint applies to inactive scenes, source modes, tests and duplicates.
        let other=model.scenes.first {!$0.testScene && $0.texture != nil}!.id
        for textured in [false,true] {
            model.setRoute("brightness",sceneID:other,textured:textured) {$0.output.transport = .osc;$0.output.address="/qa/other"}
            precondition(model.route(for:"brightness",sceneID:other,textured:textured).output.port==b.port!)
        }
        model.setRoute("speed") {$0.output.enabled=true;$0.output.transport = .osc;$0.output.address="/qa/continuous";$0.output.port=a.port!}
        precondition(model.outputIssue(for:"speed") != nil,"Shared destination must detect a duplicate address even if legacy ports differ")
        model.clearControlOutput("speed")
        model.testControlOutput(key)
        precondition(model.controlOutputEnabled,"A manual send test must not disable automatic output")
        wait("manual output test to common B") {b.count("/qa/event")==3}
        precondition(!model.setOSCOutputDestination(.init(host:"https://bad",port:9001)))
        precondition(!model.setOSCOutputDestination(.init(host:"",port:9001)))
        precondition(!model.setOSCOutputDestination(.init(host:"127.0.0.1",port:65536)))
        precondition(model.oscOutputDestination==destinationB)
        let oldReceive=model.port
        precondition(!model.applyOSCNetworkSettings(receivePort:"0",output:destinationA))
        precondition(model.port==oldReceive && model.oscOutputDestination==destinationB,"Invalid combined settings must be atomic")
        model.save()
        let restored=makeModel();defer {restored.shutdownForTermination()}
        precondition(restored.oscOutputDestination==destinationB)
        precondition(restored.route(for:key,sceneID:scene,textured:false).output.port==b.port!)

        // Upgrade old per-parameter settings: the current scene's enabled OSC target becomes common.
        var stored=try JSONDecoder().decode(StoredSettings.self,from:defaults.data(forKey:"OrbitSettings.v1")!)
        stored.oscOutputDestination=nil
        for id in stored.scenes.keys {
            stored.scenes[id]?.parameterRoutes=nil;stored.scenes[id]?.textureParameterRoutes=nil
        }
        var legacy=ParameterRoute.defaults(scene:scene,parameter:"brightness")
        legacy.output.transport = .osc;legacy.output.enabled=true;legacy.output.host="192.0.2.10";legacy.output.port=10001
        var oldMIDI=ParameterRoute.defaults(scene:scene,parameter:"speed")
        oldMIDI.output.transport = .midi;oldMIDI.output.minimum=32;oldMIDI.output.maximum=127
        stored.scenes[scene]?.parameterRoutes=["brightness":legacy,"speed":oldMIDI]
        stored.scenes[other]?.textureParameterRoutes=["speed":oldMIDI]
        defaults.set(try JSONEncoder().encode(stored),forKey:"OrbitSettings.v1")
        let migrated=makeModel();defer {migrated.shutdownForTermination()}
        precondition(migrated.oscOutputDestination == .init(host:"192.0.2.10",port:10001))
        precondition(migrated.route(for:key,sceneID:scene,textured:false).output.host=="192.0.2.10")
        for (id,textured) in [(scene,false),(other,true)] {
            let output=migrated.route(for:"speed",sceneID:id,textured:textured).output
            precondition(output.transport == .osc && output.port==10001)
            precondition(abs(output.minimum-32.0/127.0)<0.000001 && output.maximum==1)
        }
        precondition(migrated.mappingRows.filter {$0.route != nil}.allSatisfy {$0.route?.output.transport == .osc})
        migrated.save()
        let again=makeModel();defer {again.shutdownForTermination()}
        precondition(again.route(for:"speed",sceneID:scene,textured:false).output.minimum==32.0/127.0)
        // Scene cues, next and previous stay together; a newly appended cue never trails transport.
        let globalRows=model.mappingRows.filter {$0.globalID != nil}
        let sceneRows=globalRows.prefix(while:{$0.globalRoute?.action == .scene})
        precondition(sceneRows.count==model.scenes.count)
        precondition(sceneRows.map(\.address)==sceneRows.map(\.address).sorted {$0.localizedStandardCompare($1) == .orderedAscending})
        let sceneAddresses=globalRows.prefix(while:{$0.address.hasPrefix("/orbit/scene/")})
        precondition(sceneAddresses.count==model.scenes.count+2)
        precondition(sceneAddresses.map(\.address)==sceneAddresses.map(\.address).sorted {$0.localizedStandardCompare($1) == .orderedAscending})
        print("PASS: common OSC IP/port for continuous + repeated events + test outputs; live destination change without replay; inactive/source routing; duplicate detection; validation; persistence; legacy migration; scene-address ordering")
    }
}
