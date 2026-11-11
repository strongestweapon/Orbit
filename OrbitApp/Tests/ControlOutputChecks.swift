import Foundation
import Network
import CoreMIDI

final class Received {
    let lock = NSLock()
    private var midi: [UInt32] = []
    private var udp: [Data] = []
    private var deliveries: [ControlDelivery] = []
    private var listenPort: UInt16?
    private var connections: [NWConnection] = []
    func addMIDI(_ words: [UInt32]) {lock.lock();midi += words;lock.unlock()}
    func addUDP(_ data:Data) {lock.lock();udp.append(data);lock.unlock()}
    func addDelivery(_ value:ControlDelivery) {lock.lock();deliveries.append(value);lock.unlock()}
    func deliverySnapshot() -> [ControlDelivery] {lock.lock();defer{lock.unlock()};return deliveries}
    func setPort(_ port:UInt16) {lock.lock();listenPort=port;lock.unlock()}
    func hold(_ connection:NWConnection) {lock.lock();connections.append(connection);lock.unlock()}
    func snapshot() -> ([UInt32],[Data],UInt16?) {lock.lock();defer{lock.unlock()};return (midi,udp,listenPort)}
}

@main struct ControlOutputChecks {
    static func main() throws {
        let received = Received()
        let name = "Orbit Validation \(UUID().uuidString.prefix(8))"
        let sender = ControlOutput(portName:name)
        sender.onStatus = { log($0) }
        sender.onDelivery = { received.addDelivery($0) }
        sender.prepare()
        var source = MIDIEndpointRef()
        wait("virtual MIDI source registration") {
            for index in 0..<MIDIGetNumberOfSources() {
                let endpoint = MIDIGetSource(index)
                var text: Unmanaged<CFString>?
                if MIDIObjectGetStringProperty(endpoint,kMIDIPropertyName,&text) == noErr,
                   let text, (text.takeRetainedValue() as String) == name {source=endpoint;return true}
            }
            return false
        }
        var client = MIDIClientRef(), port = MIDIPortRef()
        precondition(MIDIClientCreateWithBlock("Orbit Validation Listener" as CFString,&client,nil) == noErr)
        precondition(MIDIInputPortCreateWithProtocol(client,"Input" as CFString,._1_0,&port,{events,_ in
            // CoreMIDI may batch several packets in one callback, including on resume.
            var packet=UnsafeRawPointer(events).advanced(by:MemoryLayout<MIDIEventList>.offset(of:\.packet)!)
                .assumingMemoryBound(to:MIDIEventPacket.self)
            for _ in 0..<events.pointee.numPackets {
                let words=UnsafeRawPointer(packet).advanced(by:MemoryLayout<MIDIEventPacket>.offset(of:\.words)!)
                    .assumingMemoryBound(to:UInt32.self)
                received.addMIDI(Array(UnsafeBufferPointer(start:words,count:Int(packet.pointee.wordCount))))
                packet=UnsafePointer(MIDIEventPacketNext(packet))
            }
        }) == noErr)
        precondition(MIDIPortConnectSource(port,source,nil) == noErr)
        defer {MIDIPortDispose(port);MIDIClientDispose(client)}

        let listener = try NWListener(using:.udp,on:.any)
        let queue = DispatchQueue(label:"orbit-validation-udp")
        listener.stateUpdateHandler = {state in if case .ready = state, let port=listener.port {received.setPort(port.rawValue)}}
        listener.newConnectionHandler = {connection in
            received.hold(connection);connection.start(queue:queue)
            receive(connection,into:received)
        }
        listener.start(queue:queue)
        defer {listener.cancel()}
        wait("UDP listener ready") {received.snapshot().2 != nil}
        var midi = ParameterOutputRoute();midi.channel=5;midi.controller=74
        var midi2 = midi;midi2.channel=2;midi2.controller=21
        var osc = ParameterOutputRoute();osc.transport = .osc;osc.port=Int(received.snapshot().2!)
        osc.address="/orbit/test/speed";osc.maximum=1
        let messages = [ControlEmission(id:"a",route:midi,value:100),ControlEmission(id:"b",route:midi2,value:64),
                        ControlEmission(id:"c",route:osc,value:0.25)]
        sender.send(messages)
        wait("MIDI and UDP first packets") {let s=received.snapshot();return s.0.count>=2 && s.1.count>=1}
        let first=received.snapshot()
        precondition(Set(first.0)==Set([UInt32(0x20B44A64),UInt32(0x20B11540)]),"Wrong MIDI CC/channel/value: \(first.0)")
        precondition(first.1[0].starts(with:Data("/orbit/test/speed\0".utf8)))
        precondition(Array(first.1[0].suffix(4)) == [62,128,0,0],"Wrong OSC float wire value")
        wait("per-parameter local delivery receipts") {received.deliverySnapshot().count==3}
        let deliveries=received.deliverySnapshot()
        precondition(Set(deliveries.map(\.id))==Set(["a","b","c"]))
        precondition(deliveries.allSatisfy {$0.error==nil && abs($0.at.timeIntervalSinceNow)<5})
        precondition(deliveries.first {$0.id=="c"}?.value==0.25)
        precondition(deliveries.first {$0.id=="a"}?.destination==midi.destinationKey)
        sender.send(messages)
        pump(0.3)
        let same=received.snapshot()
        precondition(same.0.count==2 && same.1.count==1,"Unchanged values were not coalesced")
        precondition(received.deliverySnapshot().count==3,"Coalesced frames must not claim another transmission")
        sender.send([ControlEmission(id:"c",route:osc,value:0.5)],force:true)
        wait("forced UDP test packet") {received.snapshot().1.count==2}
        precondition(Array(received.snapshot().1[1].suffix(4)) == [63,0,0,0])
        wait("forced output delivery") {received.deliverySnapshot().last?.value==0.5}
        sender.reset();sender.send(messages)
        wait("reset/resume MIDI packets") {received.snapshot().0.count>=4}
        wait("reset/resume UDP packets") {received.snapshot().1.count>=3}
        print("PASS: real CoreMIDI + UDP loopback, per-parameter delivery status/values, change coalescing, forced test, reset/resume")
        withExtendedLifetime(sender) {}
    }
    static func receive(_ connection:NWConnection,into received:Received) {
        connection.receiveMessage {data,_,_,error in
            if let data {received.addUDP(data)}
            if error == nil {receive(connection,into:received)}
        }
    }
    static func wait(_ name:String,_ ready:()->Bool) {
        log("Waiting: \(name)")
        let deadline=Date().addingTimeInterval(20)
        while !ready() {precondition(Date()<deadline,"Timed out: \(name)");pump(0.01)}
    }
    static func log(_ text:String) {FileHandle.standardError.write(Data((text+"\n").utf8))}
    static func pump(_ duration:Double) {RunLoop.current.run(until:Date().addingTimeInterval(duration))}
}
