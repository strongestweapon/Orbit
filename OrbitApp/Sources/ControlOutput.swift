import Foundation
import Network
import CoreMIDI

struct ControlEmission {
    let id: String
    let route: ParameterOutputRoute
    let value: Double
}

/// A virtual MIDI input visible to Live, plus independently addressed OSC/UDP destinations.
final class ControlOutput {
    var onStatus: ((String) -> Void)?
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
    func send(_ emissions: [ControlEmission], force: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if !force {
                let ids = Set(emissions.map(\.id))
                self.sent = self.sent.filter { ids.contains($0.key) }
                let hosts = Set(emissions.filter { $0.route.transport == .osc }.map { "\($0.route.host):\($0.route.port)" })
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
                    }
                } else {
                    self.sendOSC(emission,value:value,now:now,force:force)
                }
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
        let route = emission.route
        guard let port = NWEndpoint.Port(rawValue:UInt16(route.port)),
              let data = OSCEncoder.floatMessage(address:route.address,value:Float(value)) else { return }
        let key = "\(route.host):\(route.port)"
        guard now >= (retryAfter[key] ?? 0) else { return }
        let connection: NWConnection
        if let existing = connections[key] { connection = existing }
        else {
            connection = NWConnection(host:NWEndpoint.Host(route.host),port:port,using:.udp)
            connections[key] = connection; connection.start(queue:queue)
        }
        let generation = epoch
        sent[emission.id] = (route.destinationKey,value,now)
        connection.send(content:data,completion:.contentProcessed { [weak self, weak connection] error in
            guard let self, self.epoch == generation else { return }
            if let error {
                if self.sent[emission.id]?.destination == route.destinationKey { self.sent.removeValue(forKey:emission.id) }
                self.retryAfter[key] = ProcessInfo.processInfo.systemUptime+2
                if self.connections[key] === connection { self.connections.removeValue(forKey:key)?.cancel() }
                self.report("OSC 송신 실패 · \(error.localizedDescription)")
            } else {
                self.report(force ? "OSC 테스트 송신 · \(route.address)" : "OSC 송신 · \(key) (수신 확인 아님)")
            }
        })
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
