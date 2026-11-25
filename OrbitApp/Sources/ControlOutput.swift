import Foundation
import Network
import CoreMIDI

struct ControlEmission {
    let id: String
    let route: ParameterOutputRoute
    let value: Double
}

struct ControlDelivery {
    let id: String
    let destination: String
    let value: Double
    let at: Date
    let error: String?
}

/// A virtual MIDI input visible to Live, plus independently addressed OSC/UDP destinations.
final class ControlOutput {
    var onStatus: ((String) -> Void)?
    /// Local transport completion, not acknowledgement from Live or an OSC receiver.
    var onDelivery: ((ControlDelivery) -> Void)?
    private let queue = DispatchQueue(label:"studio.superless.orbit.control-output")
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var connections: [String:NWConnection] = [:]
    private var retryAfter: [String:TimeInterval] = [:]
    private var sent: [String:(destination:String,value:Double,time:TimeInterval)] = [:]
    private var epoch = 0
    private var status = ""
    let portName: String
    init(portName: String = "Orbit Control") { self.portName = portName }

    func prepare() { queue.async { [weak self] in _ = self?.prepareMIDI() } }
    private func prepareMIDI() -> Bool {
        if source != 0 { return true }
        if client == 0 {
            let result = MIDIClientCreateWithBlock("Orbit" as CFString,&client,nil)
            guard result == noErr else { report("MIDI 초기화 실패 · \(result)"); return false }
        }
        let result = MIDISourceCreateWithProtocol(client,portName as CFString,._1_0,&source)
        guard result == noErr else { report("MIDI 포트 생성 실패 · \(result)"); return false }
        report("MIDI 준비 · \(portName)"); return true
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.epoch += 1; self.sent.removeAll(); self.retryAfter.removeAll(); self.status = ""
            self.connections.values.forEach { $0.cancel() }; self.connections.removeAll()
        }
    }
    func send(_ emissions: [ControlEmission], force: Bool = false, retaining eventRoutes: [ParameterOutputRoute] = []) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if !force {
                let ids = Set(emissions.map(\.id))
                self.sent = self.sent.filter { ids.contains($0.key) }
                let hosts = Set((emissions.map(\.route) + eventRoutes).filter { $0.transport == .osc }.map { "\($0.host):\($0.port)" })
                for key in Array(self.connections.keys) where !hosts.contains(key) {
                    self.connections.removeValue(forKey:key)?.cancel()
                }
            }
            for emission in emissions where emission.route.validationError == nil && emission.value.isFinite {
                let route = emission.route
                let value = route.transport == .midi ? min(127,max(0,emission.value.rounded())) : emission.value
                if !force, let prior = self.sent[emission.id], prior.destination == route.destinationKey,
                   abs(prior.value-value) < (route.transport == .midi ? 0.5 : 0.0001), now-prior.time < 2 { continue }
                if route.transport == .midi {
                    if self.sendMIDI(channel:route.channel,controller:route.controller,value:Int(value)) {
                        self.sent[emission.id] = (route.destinationKey,value,now)
                        self.report(force ? "MIDI 테스트 송신 · CH \(route.channel) CC \(route.controller)" : "MIDI 송신 · \(self.portName)")
                        self.delivered(emission,value:value)
                    } else {
                        self.delivered(emission,value:value,error:"MIDI 송신 실패")
                    }
                } else {
                    self.sendOSC(emission,value:value,now:now,force:force)
                }
            }
        }
    }
    /// One call is one event. Identical consecutive events must never be coalesced.
    /// Correlated OSC values for a destination travel together in one immediate bundle.
    func sendEvents(_ emissions: [ControlEmission], test: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            let valid = emissions.filter { $0.route.validationError == nil && $0.value.isFinite }
            for emission in valid where emission.route.transport == .midi {
                let value = min(127,max(0,emission.value.rounded()))
                if self.sendMIDI(channel:emission.route.channel,controller:emission.route.controller,value:Int(value)) {
                    self.delivered(emission,value:value); self.report(test ? "MIDI 이벤트 테스트 송신" : "MIDI 이벤트 송신 · \(self.portName)")
                } else { self.delivered(emission,value:value,error:"MIDI 이벤트 송신 실패") }
            }
            let groups = Dictionary(grouping:valid.filter { $0.route.transport == .osc }) { "\($0.route.host):\($0.route.port)" }
            for group in groups.values {
                let messages = group.compactMap { OSCEncoder.floatMessage(address:$0.route.address,value:Float($0.value)) }
                guard messages.count == group.count else { continue }
                self.sendOSCPacket(group,data:OSCEncoder.immediateBundle(messages),now:ProcessInfo.processInfo.systemUptime,label:test ? "OSC 이벤트 테스트 송신" : "OSC 이벤트 송신")
            }
        }
    }
    private func sendMIDI(channel: Int, controller: Int, value: Int) -> Bool {
        guard prepareMIDI() else { return false }
        var events = MIDIEventList()
        let result: OSStatus = withUnsafeMutablePointer(to:&events) { list in
            let packet = MIDIEventListInit(list,._1_0)
            var word = UInt32(0x20B00000) | (UInt32(channel-1)<<16) | (UInt32(controller)<<8) | UInt32(value)
            _ = MIDIEventListAdd(list,MemoryLayout<MIDIEventList>.size,packet,0,1,&word)
            return MIDIReceivedEventList(source,list)
        }
        if result != noErr { report("MIDI 송신 실패 · \(result)") }
        return result == noErr
    }
    private func sendOSC(_ emission: ControlEmission, value: Double, now: TimeInterval, force: Bool) {
        guard let data = OSCEncoder.floatMessage(address:emission.route.address,value:Float(value)) else { return }
        guard now >= (retryAfter["\(emission.route.host):\(emission.route.port)"] ?? 0) else { return }
        sent[emission.id] = (emission.route.destinationKey,value,now)
        sendOSCPacket([emission],data:data,now:now,label:force ? "OSC 테스트 송신" : "OSC 송신")
    }
    private func sendOSCPacket(_ emissions: [ControlEmission], data: Data, now: TimeInterval, label: String) {
        guard let route = emissions.first?.route, let port = NWEndpoint.Port(rawValue:UInt16(route.port)) else { return }
        let key = "\(route.host):\(route.port)"
        guard now >= (retryAfter[key] ?? 0) else { return }
        let connection: NWConnection
        if let existing = connections[key] { connection = existing }
        else {
            connection = NWConnection(host:NWEndpoint.Host(route.host),port:port,using:.udp)
            connections[key] = connection; connection.start(queue:queue)
        }
        let generation = epoch
        connection.send(content:data,completion:.contentProcessed { [weak self, weak connection] error in
            guard let self, self.epoch == generation else { return }
            if let error {
                for emission in emissions where self.sent[emission.id]?.destination == emission.route.destinationKey {
                    self.sent.removeValue(forKey:emission.id)
                }
                self.retryAfter[key] = ProcessInfo.processInfo.systemUptime+2
                if self.connections[key] === connection { self.connections.removeValue(forKey:key)?.cancel() }
                self.report("OSC 송신 실패 · \(error.localizedDescription)")
                for emission in emissions { self.delivered(emission,value:emission.value,error:error.localizedDescription) }
            } else {
                self.report("\(label) · \(key) (수신 확인 아님)")
                for emission in emissions { self.delivered(emission,value:emission.value) }
            }
        })
    }
    private func delivered(_ emission: ControlEmission, value: Double, error: String? = nil) {
        onDelivery?(ControlDelivery(id:emission.id,destination:emission.route.destinationKey,value:value,at:Date(),error:error))
    }
    private func report(_ text: String) {
        guard status != text else { return }; status = text; onStatus?(text)
    }
    deinit {
        connections.values.forEach { $0.cancel() }
        if source != 0 { MIDIEndpointDispose(source) }
        if client != 0 { MIDIClientDispose(client) }
    }
}
