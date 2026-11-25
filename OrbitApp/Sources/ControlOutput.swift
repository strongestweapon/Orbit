import Foundation
import Network

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
    var signal: String = ""
}

/// OSC float output. Each event remains a distinct UDP bundle.
final class ControlOutput {
    var onStatus: ((String) -> Void)?
    /// Local transport completion, not acknowledgement from Live or an OSC receiver.
    var onDelivery: ((ControlDelivery) -> Void)?
    private let queue = DispatchQueue(label:"studio.superless.orbit.control-output")
    private var connections: [String:NWConnection] = [:]
    private var retryAfter: [String:TimeInterval] = [:]
    private var sent: [String:(destination:String,value:Double,time:TimeInterval)] = [:]
    private var epoch = 0
    private var status = ""
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
                let value = emission.value
                if !force, let prior = self.sent[emission.id], prior.destination == route.destinationKey,
                   abs(prior.value-value) < 0.0001, now-prior.time < 2 { continue }
                self.sendOSC(emission,value:value,now:now,force:force)
            }
        }
    }
    /// One call is one event. Identical consecutive events must never be coalesced.
    /// Correlated OSC values for a destination travel together in one immediate bundle.
    func sendEvents(_ emissions: [ControlEmission], test: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            let valid = emissions.filter { $0.route.validationError == nil && $0.value.isFinite }
            let groups = Dictionary(grouping:valid.filter { $0.route.transport == .osc }) { "\($0.route.host):\($0.route.port)" }
            for group in groups.values {
                let messages = group.compactMap { OSCEncoder.floatMessage(address:$0.route.address,value:Float($0.value)) }
                guard messages.count == group.count else { continue }
                self.sendOSCPacket(group,data:OSCEncoder.immediateBundle(messages),now:ProcessInfo.processInfo.systemUptime,label:test ? "OSC 이벤트 테스트 송신" : "OSC 이벤트 송신")
            }
        }
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
        onDelivery?(ControlDelivery(id:emission.id,destination:emission.route.destinationKey,value:value,at:Date(),error:error,
                                   signal:emission.route.address))
    }
    private func report(_ text: String) {
        guard status != text else { return }; status = text; onStatus?(text)
    }
    deinit {
        connections.values.forEach { $0.cancel() }
    }
}
