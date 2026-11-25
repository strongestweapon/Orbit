import Foundation
import Network
import Darwin

struct OSCNetworkAddress: Identifiable {
    let interface: String
    let address: String
    var id: String {interface+":"+address}
    static func current() -> [Self] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0,let first=head else {return []}
        defer {freeifaddrs(first)}
        var results:[Self]=[]
        var cursor:UnsafeMutablePointer<ifaddrs>?=first
        while let item=cursor {
            defer {cursor=item.pointee.ifa_next}
            let entry=item.pointee
            guard let socket=entry.ifa_addr,Int32(entry.ifa_flags) & IFF_UP != 0,
                  Int32(entry.ifa_flags) & IFF_LOOPBACK == 0,socket.pointee.sa_family == UInt8(AF_INET) else {continue}
            var host=[CChar](repeating:0,count:Int(NI_MAXHOST))
            guard getnameinfo(socket,socklen_t(socket.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST)==0 else {continue}
            results.append(.init(interface:String(cString:entry.ifa_name),address:String(cString:host)))
        }
        return results.sorted {
            if $0.interface.hasPrefix("en") != $1.interface.hasPrefix("en") {return $0.interface.hasPrefix("en")}
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }
}

struct OSCMessage { let address: String; let values: [Double] }

enum OSCDecoder {
    static func decode(_ data: Data, depth: Int = 0) -> [OSCMessage] {
        guard depth < 8, data.count <= 65536 else { return [] }
        let bytes = [UInt8](data)
        if bytes.starts(with: Array("#bundle\0".utf8)) {
            guard bytes.count >= 16 else { return [] }
            var offset = 16; var messages: [OSCMessage] = []
            while offset + 4 <= bytes.count {
                let size = Int(word(bytes, offset)); offset += 4
                guard size > 0, size <= bytes.count - offset else { return [] }
                messages += decode(Data(bytes[offset..<offset+size]), depth: depth + 1); offset += size
            }
            return messages
        }
        var offset = 0
        guard let address = string(bytes, &offset), address.hasPrefix("/"),
              let tags = string(bytes, &offset), tags.hasPrefix(",") else { return [] }
        var values: [Double] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "f", "i":
                guard offset + 4 <= bytes.count else { return [] }
                let raw = word(bytes, offset); offset += 4
                values.append(tag == "f" ? Double(Float(bitPattern: raw)) : .nan)
            case "d", "h":
                guard offset + 8 <= bytes.count else { return [] }
                let raw = UInt64(word(bytes,offset)) << 32 | UInt64(word(bytes,offset+4)); offset += 8
                values.append(tag == "d" ? Double(bitPattern: raw) : .nan)
            case "T", "F": values.append(.nan)
            case "s":
                guard string(bytes,&offset) != nil else { return [] }; values.append(.nan)
            default: return []
            }
        }
        return [OSCMessage(address: address,values: values)]
    }
    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private static func string(_ bytes: [UInt8], _ offset: inout Int) -> String? {
        guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
        let value = String(bytes: bytes[offset..<end],encoding: .utf8)
        offset = (end + 4) & ~3
        guard offset <= bytes.count else { return nil }
        return value
    }
}

final class OSCReceiver {
    var onState: ((Bool,String) -> Void)?
    var onMessage: ((String,[Double]) -> Void)?
    private let queue = DispatchQueue(label: "studio.superless.orbit.osc")
    private var listener: NWListener?
    private var connections: [UUID:NWConnection] = [:]
    func start(port: UInt16) {
        stop()
        do {
            let listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.onState?(true,"UDP \(port) · 수신 대기")
                case .failed(let error): self?.onState?(false,error.localizedDescription)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                let id = UUID(); self.connections[id] = connection
                connection.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.connections.removeValue(forKey:id) }
                    if case .cancelled = state { self?.connections.removeValue(forKey:id) }
                }
                connection.start(queue:self.queue); self.receive(connection,id:id)
            }
            listener.start(queue:queue)
        } catch { onState?(false,error.localizedDescription) }
    }
    private func receive(_ connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data { for m in OSCDecoder.decode(data) { self.onMessage?(m.address,m.values) } }
            if error == nil { self.receive(connection,id:id) }
            else { connection.cancel(); self.connections.removeValue(forKey:id) }
        }
    }
    func stop() {
        listener?.cancel(); listener = nil
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
    }
    deinit { listener?.cancel(); for connection in connections.values { connection.cancel() } }
}
