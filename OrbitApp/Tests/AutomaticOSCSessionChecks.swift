import AppKit
import Network
import Darwin

final class AutomaticOSCInbox {
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

@main struct AutomaticOSCSessionChecks {
    static func pump(_ seconds:Double) {RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
    static func wait(_ message:String,_ predicate:()->Bool) {
        let end=Date().addingTimeInterval(10)
        while !predicate() {precondition(Date()<end,message);pump(0.01)}
    }
    static func freePort()->UInt16 {
        let fd=socket(AF_INET,SOCK_DGRAM,0);precondition(fd>=0);defer {Darwin.close(fd)}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET)
        address.sin_addr.s_addr=inet_addr("127.0.0.1")
        let bound=withUnsafePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        precondition(bound==0)
        var size=socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to:&address) {ptr in _=ptr.withMemoryRebound(to:sockaddr.self,capacity:1) {getsockname(fd,$0,&size)}}
        return UInt16(bigEndian:address.sin_port)
    }
    static func main() throws {
        let inbox=try AutomaticOSCInbox();defer {inbox.stop()}
        wait("output listener") {inbox.port != nil}
        let domain="studio.superless.Orbit.automatic-osc-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:domain)!,resources=Bundle(path:CommandLine.arguments[1])!
        defer {defaults.removePersistentDomain(forName:domain)}
        func make()->OrbitModel {OrbitModel(defaults:defaults,resources:resources,controlOutput:ControlOutput())}
        let fixture=make()
        fixture.playing=false;fixture.resumeOnLaunch=false;fixture.port=String(freePort())
        fixture.selectedSceneID=PulseOrbitSimulation.sceneID
        let event=SceneTrigger.addLineID
        let destination=OSCOutputDestination(host:"127.0.0.1",port:inbox.port!)
        precondition(fixture.setOSCOutputDestination(destination))
        fixture.setNormalizedParameterValue("brightness",0.4)
        fixture.setRoute("brightness") {$0.output.enabled=true;$0.output.address="/qa/value"}
        fixture.setRoute(event) {$0.output.enabled=true;$0.output.address="/qa/event"}
        fixture.globalOSC.removeAll {$0.action == .pause}
        let playIndex=fixture.globalOSC.firstIndex {$0.action == .play}!
        fixture.globalOSC[playIndex].address="/qa/custom-play"
        fixture.shutdownForTermination()
        let legacy=try JSONDecoder().decode(StoredSettings.self,from:defaults.data(forKey:"OrbitSettings.v1")!)
        precondition(legacy.installation?.controlSending==false && legacy.installation?.oscReceiving==false)
        let model=make();defer {model.shutdownForTermination()}
        precondition(!model.resumeOnLaunch)
        model.restoreSessionOnce()
        wait("automatic receive despite old disabled state") {model.oscRunning}
        wait("per-item output starts without master switch") {abs((inbox.latest("/qa/value") ?? -1)-0.4)<0.00001}
        precondition(model.hasActiveControlOutput && model.blocksUpdateInstallation)
        precondition(model.globalOSC.contains {$0.action == .pause && $0.address=="/orbit/pause"})
        precondition(model.globalOSC.contains {$0.action == .play && $0.address=="/qa/custom-play"})
        precondition(inbox.count("/qa/event")==0,"Restoring a checked event must not replay it")
        var clients:[NWConnection]=[];defer {clients.forEach {$0.cancel()}}
        func sender(_ port:String)->NWConnection {
            let c=NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:UInt16(port)!)!,using:.udp)
            c.start(queue:DispatchQueue(label:"automatic-osc-input"));clients.append(c);return c
        }
        func send(_ c:NWConnection,_ address:String,_ value:Float) {c.send(content:OSCEncoder.floatMessage(address:address,value:value),completion:.contentProcessed({_ in}))}
        let input=model.inputOSCAddress(event,sceneID:model.selectedSceneID,textured:false)
        let client=sender(model.port)
        for _ in 0..<3 {send(client,input,0.5)}
        wait("every repeated trigger is sent once") {model.pulseLineCount==6 && inbox.count("/qa/event")==3}
        model.setRoute(event) {$0.output.enabled=false}
        send(client,input,1)
        wait("input still works after output unchecked") {model.pulseLineCount==7}
        pump(0.15);precondition(inbox.count("/qa/event")==3)
        model.setRoute("brightness") {$0.output.enabled=false}
        pump(0.15)
        precondition(!model.hasActiveControlOutput && !model.blocksUpdateInstallation,"An idle OSC listener must not block updates")
        let oldValueCount=inbox.count("/qa/value")
        model.setNormalizedParameterValue("brightness",0.7);pump(0.15)
        precondition(inbox.count("/qa/value")==oldValueCount)
        model.setRoute("brightness") {$0.output.enabled=true}
        wait("one checkbox resumes current value") {abs((inbox.latest("/qa/value") ?? -1)-0.7)<0.00001}
        model.setRoute(event) {$0.output.enabled=true}
        pump(0.15);precondition(inbox.count("/qa/event")==3)
        model.triggerParameter(event)
        wait("manual main button sends checked event") {inbox.count("/qa/event")==4}
        let lineCount=model.pulseLineCount
        model.restoreSessionOnce();precondition(model.pulseLineCount==lineCount)
        // Applying valid network settings restarts the listener and recovers an interrupted listener.
        let nextPort=String(freePort())
        precondition(model.applyOSCNetworkSettings(receivePort:nextPort,output:destination))
        wait("new receive port") {model.oscRunning && model.port==nextPort}
        let changedClient=sender(nextPort)
        send(changedClient,input,1)
        wait("new port receives") {model.parameterEventCount(event)==1}
        model.stopOSC()
        precondition(model.applyOSCNetworkSettings(receivePort:nextPort,output:destination))
        wait("same-port retry") {model.oscRunning}
        send(changedClient,input,1)
        wait("reconnected listener") {model.parameterEventCount(event)==1}
        model.selectedSceneID="06_calibration"
        precondition(!model.hasActiveControlOutput && !model.blocksUpdateInstallation)
        model.shutdownForTermination()
        model.restoreSessionOnce();precondition(!model.oscRunning && !model.controlOutputEnabled)
        print("PASS: automatic OSC at launch with old master states off; per-item continuous/event output; repeated UDP cues; checkbox stop/resume; no trigger replay; global catalog repair/custom addresses; port change/retry; idle update eligibility; shutdown")
    }
}
