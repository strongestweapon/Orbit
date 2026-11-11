import Foundation

struct SensorInput: Identifiable, Codable {
    var id = UUID()
    var name: String
    var address: String
    var argument = 0
    var minimum: Double = 0
    var maximum: Double = 100
    var value: Double?
    var receivedAt: Date?
}

// Kept for decoding existing installations; new routing is indexed by parameter.
struct SensorMapping: Codable, Equatable {
    var sensorID: UUID?
    var target = "energy"
    var minimum: Double = 0.25
    var maximum: Double = 0.9
    var smoothingSeconds: Double = 8
    var enabled = false
}

struct ParameterSpec: Identifiable {
    let id: String
    let title: String
    var range: ClosedRange<Double> = 0...1
    var isSwitch = false
    var detail = ""
    var unit = ""
    var defaultCC: Int?
    static let all: [ParameterSpec] = [
        .init(id:"speed",title:"속도",range:0...3), .init(id:"brightness",title:"밝기"),
        .init(id:"energy",title:"에너지"), .init(id:"density",title:"밀도"),
        .init(id:"hueShift",title:"색상 이동",range:-0.5...0.5),
        .init(id:"turbulence",title:"움직임"), .init(id:"coverage",title:"빛이 남는 범위"),
        .init(id:"gapSoftness",title:"소멸 경계 부드러움"), .init(id:"gapMotion",title:"빈 구간 이동"),
        .init(id:"fragmentation",title:"조각화"), .init(id:"rotation",title:"전체 회전"),
        .init(id:"angleOffset",title:"링 시작점"), .init(id:"flipU",title:"진행 방향 반전",isSwitch:true),
        .init(id:"flipV",title:"안쪽 / 바깥쪽 반전",isSwitch:true)
    ]
    static func find(_ key: String) -> ParameterSpec { all.first { $0.id == key } ?? .init(id:key,title:key) }
    func clamp(_ value: Double) -> Double {
        let number = value.isFinite ? min(range.upperBound,max(range.lowerBound,value)) : range.lowerBound
        return isSwitch ? (number >= 0.5 ? 1 : 0) : number
    }
}

/// Public shader controls are separate from the stable GPU buffer slots.
struct ShaderParameter: Decodable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let uniform: String
    let defaultValue: Double
    let minimum: Double
    let maximum: Double
    let group: Int
    let quick: Bool
    let unit: String
    let legacyKey: String?
    let midiCC: Int?
    func spec(index: Int) -> ParameterSpec {
        ParameterSpec(id:id,title:title,range:minimum...maximum,detail:detail,unit:unit,defaultCC:midiCC ?? (40+index))
    }
}

struct ParameterInputRoute: Codable, Equatable {
    var enabled = false
    var sensorID: UUID?
    var minimum: Double = 0
    var maximum: Double = 1
    var smoothingSeconds: Double = 8
}

enum ControlTransport: String, Codable, CaseIterable, Identifiable {
    case midi, osc
    var id: String { rawValue }
    var label: String { self == .midi ? "Ableton · MIDI CC" : "OSC · UDP" }
}

struct ParameterOutputRoute: Codable, Equatable {
    var enabled = false
    var transport: ControlTransport = .midi
    var channel = 1
    var controller = 20
    var host = "127.0.0.1"
    var port = 9001
    var address = "/orbit/value"
    var minimum: Double = 0
    var maximum: Double = 127
    var destinationKey: String {
        transport == .midi ? "midi:\(channel):\(controller)" : "osc:\(host.trimmingCharacters(in:.whitespaces)):\(port):\(address)"
    }
    var validationError: String? {
        guard minimum.isFinite, maximum.isFinite else { return "송신 범위에 유효한 숫자를 입력하세요." }
        if transport == .midi {
            guard (1...16).contains(channel), (0...119).contains(controller) else { return "채널 1–16, CC 0–119를 사용하세요." }
            guard (0...127).contains(minimum), (0...127).contains(maximum) else { return "MIDI 값은 0–127 범위입니다." }
        } else {
            guard !host.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  !host.contains(where: { $0.isWhitespace }), (1...65535).contains(port) else { return "대상 IP/호스트와 UDP 포트를 확인하세요." }
            guard address.hasPrefix("/"), address.utf8.count <= 1024,
                  !address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
                return "OSC 주소는 /로 시작하고 공백 없이 입력하세요."
            }
            guard abs(minimum) <= Double(Float.greatestFiniteMagnitude), abs(maximum) <= Double(Float.greatestFiniteMagnitude) else {
                return "OSC float 범위를 벗어났습니다."
            }
        }
        return nil
    }
    func mappedValue(_ value: Double, spec: ParameterSpec) -> Double? {
        guard validationError == nil, value.isFinite else { return nil }
        let n = (spec.clamp(value)-spec.range.lowerBound)/(spec.range.upperBound-spec.range.lowerBound)
        let result = minimum + n*(maximum-minimum)
        return transport == .midi ? result.rounded() : result
    }
}

struct ParameterRoute: Codable, Equatable {
    var input = ParameterInputRoute()
    var output = ParameterOutputRoute()
    static func defaults(scene: String, parameter: String, spec supplied: ParameterSpec? = nil) -> ParameterRoute {
        let spec = supplied ?? ParameterSpec.find(parameter)
        var route = ParameterRoute()
        route.input.minimum = spec.range.lowerBound; route.input.maximum = spec.range.upperBound
        route.output.controller = spec.defaultCC ?? (20 + (ParameterSpec.all.firstIndex { $0.id == parameter } ?? 0))
        route.output.address = "/orbit/\(scene)/\(parameter)"
        return route
    }
}

struct SceneSettings: Codable {
    var values: [String: Float]
    var speed: Float
    var mapping = SensorMapping()
    var useTexture: Bool?
    var textureMapping: SensorMapping?
    var parameterRoutes: [String:ParameterRoute]?
    var textureParameterRoutes: [String:ParameterRoute]?

    mutating func migrateRoutes(scene: String) {
        if parameterRoutes == nil { parameterRoutes = migrate(mapping,scene:scene) }
        if textureParameterRoutes == nil { textureParameterRoutes = migrate(textureMapping,scene:scene) }
    }
    mutating func migrateShaderParameters(_ parameters: [ShaderParameter]) {
        // Preserve explicit new values and endpoints. Texture playback keeps its own controls.
        for parameter in parameters {
            guard let old = parameter.legacyKey else { continue }
            if values[parameter.id] == nil, let value = values[old] { values[parameter.id] = value }
            if parameterRoutes?[parameter.id] == nil, let route = parameterRoutes?[old] {
                parameterRoutes?[parameter.id] = route
            }
            parameterRoutes?.removeValue(forKey:old)
        }
    }
    private func migrate(_ legacy: SensorMapping?, scene: String) -> [String:ParameterRoute] {
        guard let legacy, legacy.enabled || legacy.sensorID != nil else { return [:] }
        var route = ParameterRoute.defaults(scene:scene,parameter:legacy.target)
        route.input = ParameterInputRoute(enabled:legacy.enabled,sensorID:legacy.sensorID,
            minimum:legacy.minimum,maximum:legacy.maximum,smoothingSeconds:legacy.smoothingSeconds)
        return [legacy.target:route]
    }
}

/// One independent smoothing state for every parameter; called by a render-independent control clock.
struct ParameterResolver {
    private var smoothed: [String:Double] = [:]
    mutating func reset() { smoothed.removeAll() }
    mutating func resolve(base: [String:Double], routes: [String:ParameterRoute], sensors: [SensorInput],
                          now: Date, delta: Double, specs: [ParameterSpec] = ParameterSpec.all) -> [String:Double] {
        var result = base
        for spec in specs {
            guard let rawBase = base[spec.id] else { continue }
            let fallback = spec.clamp(rawBase)
            guard let route = routes[spec.id]?.input, route.enabled else {
                result[spec.id] = fallback; smoothed.removeValue(forKey:spec.id); continue
            }
            var target = fallback
            if let sensor = sensors.first(where: { $0.id == route.sensorID }),
               let value = sensor.value, value.isFinite, let received = sensor.receivedAt,
               now.timeIntervalSince(received) < 90, sensor.maximum > sensor.minimum,
               sensor.minimum.isFinite, sensor.maximum.isFinite,
               route.minimum.isFinite, route.maximum.isFinite {
                let n = min(1,max(0,(value-sensor.minimum)/(sensor.maximum-sensor.minimum)))
                target = spec.clamp(route.minimum+n*(route.maximum-route.minimum))
            }
            let seconds = route.smoothingSeconds.isFinite ? max(0,route.smoothingSeconds) : 0
            let blend = seconds == 0 ? 1 : 1-exp(-max(0,delta)*3/seconds)
            let prior = smoothed[spec.id] ?? fallback
            let value = prior+(target-prior)*blend
            smoothed[spec.id] = value; result[spec.id] = spec.clamp(value)
        }
        return result
    }
}

enum OSCEncoder {
    static func floatMessage(address: String, value: Float) -> Data? {
        guard address.hasPrefix("/"), !address.utf8.contains(0), value.isFinite else { return nil }
        func string(_ text: String) -> Data {
            var bytes = Data(text.utf8); bytes.append(0)
            while bytes.count % 4 != 0 { bytes.append(0) }
            return bytes
        }
        var data = string(address); data.append(string(",f"))
        var bits = value.bitPattern.bigEndian
        withUnsafeBytes(of:&bits) { data.append(contentsOf:$0) }
        return data
    }
}
