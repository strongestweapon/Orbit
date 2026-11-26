import Foundation

struct SensorInput: Identifiable, Codable {
    var id = UUID()
    var name: String
    var address: String
    var argument = 0
    var minimum: Double = 0
    var maximum: Double = 1
    var value: Double?
    var receivedAt: Date?

    func receptionState(running: Bool, now: Date) -> SensorReceptionState {
        guard running else { return .stopped }
        guard value?.isFinite == true, let receivedAt else { return .waiting }
        return now.timeIntervalSince(receivedAt) < 90 ? .receiving : .stale
    }
}

enum SensorReceptionState: String {
    case stopped = "수신 꺼짐", waiting = "수신 대기", receiving = "수신됨", stale = "90초 이상 없음"
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
    var outputOnly = false
    var eventOutput = false
    var isTrigger = false
    var supportsOutputMode: Bool { !isTrigger && id != PulseOrbitOutputs.trigger }
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
    static func find(_ key: String) -> ParameterSpec { (all + PulseOrbitOutputs.specs).first { $0.id == key } ?? .init(id:key,title:key,eventOutput:key.hasPrefix("trigger."),isTrigger:key.hasPrefix("trigger.")) }
    func clamp(_ value: Double) -> Double {
        let number = value.isFinite ? min(range.upperBound,max(range.lowerBound,value)) : range.lowerBound
        return isSwitch ? (number >= 0.5 ? 1 : 0) : number
    }
    /// Operator controls and OSC use 0...1. Stored values and GPU uniforms retain their native range.
    func normalized(_ value: Double) -> Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(1,max(0,(clamp(value)-range.lowerBound)/(range.upperBound-range.lowerBound)))
    }
    func rawValue(normalized value: Double) -> Double {
        let unit = value.isFinite ? min(1,max(0,value)) : 0
        return clamp(range.lowerBound+unit*(range.upperBound-range.lowerBound))
    }
}

/// Actual simulation signals, separate from the controls that tune the picture.
enum PulseOrbitOutputs {
    static let trigger = "crossingTrigger"
    static let angle = "crossingAngle"
    static let strength = "crossingStrength"
    static let proximity = "proximity"
    static let accentAngle = "accentAngle"
    static let accentStrength = "accentStrength"
    static func isCrossing(_ key: String) -> Bool {[trigger,angle,strength].contains(key)}
    static let specs: [ParameterSpec] = [
        .init(id:accentAngle,title:"사건 위치",detail:"최근 강조 띠의 생성 위치입니다. 송신 가능한 큐가 선택되면 같은 OSC bundle에서 이벤트보다 먼저 보냅니다. 0/1은 12시입니다.",outputOnly:true,eventOutput:true),
        .init(id:accentStrength,title:"사건 강도",detail:"최근 강조 띠의 강도입니다. 큐와 함께 한 번 보냅니다.",outputOnly:true,eventOutput:true),
        .init(id:trigger,title:"교차 발생",detail:"실제 교차를 OSC 1.0으로 보냅니다. 자연 발생 교차만 6초에 최대 1회이며 버튼·외부 OSC 트리거는 매번 즉시 송신합니다.",defaultCC:90,outputOnly:true,eventOutput:true),
        .init(id:angle,title:"교차 위치",detail:"교차할 때의 논리 링 위치입니다. 0/1은 12시, 0.25는 3시입니다. 영상 출력 방향 보정 전 좌표입니다.",defaultCC:91,outputOnly:true,eventOutput:true),
        .init(id:strength,title:"교차 강도",detail:"교차한 두 펄스의 실제 방출 강도 중 작은 값입니다. 교차할 때만 0–1 실수로 보냅니다.",defaultCC:92,outputOnly:true,eventOutput:true),
        .init(id:proximity,title:"현재 근접도",detail:"안팎 펄스 중 가장 강한 근접 연결입니다. 멀면 0, 같은 각도에서 밝게 만나면 1입니다. 연속 출력입니다.",defaultCC:93,outputOnly:true)
    ]
    static func address(_ key: String) -> String {
        let tail = [trigger:"crossing",angle:"angle",strength:"strength",proximity:"proximity",accentAngle:"accent/angle",accentStrength:"accent/strength"][key] ?? key
        return "/orbit/09_pulse_orbit/events/" + tail
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
    let isSwitch: Bool?
    func spec(index: Int) -> ParameterSpec {
        ParameterSpec(id:id,title:title,range:minimum...maximum,isSwitch:isSwitch ?? false,detail:detail,unit:unit,defaultCC:midiCC ?? (40+index))
    }
}

struct ParameterInputRoute: Codable, Equatable {
    var enabled = false
    var sensorID: UUID?
    var minimum: Double = 0
    var maximum: Double = 1
    var smoothingSeconds: Double = 8
    // Optional additions preserve existing installation files.
    var mode: ParameterInputMode?
    var sourceParameter: String?
    var legacyTarget: Double?
    var lineLimit: Int?
    var event: ParameterEventSettings?
    // Built-in scene addresses work without creating a sensor. Optional fields migrate old settings.
    var directOSCEnabled: Bool?
    var directOSCAddress: String?
    var directOSCArgument: Int? // Preserve the argument used by a migrated address.
    var oscArgument: Int {min(15,max(0,directOSCArgument ?? 0))}
    var receivesDirectOSC: Bool {directOSCEnabled ?? true}
    var behavior: ParameterInputMode { mode ?? .continuous }
    var eventSettings: ParameterEventSettings { (event ?? .init()).sanitized }
    func addressOnly(using legacySensors: [SensorInput]) -> Self {
        var result=self
        if sourceParameter == nil {
            if enabled, let sensor=legacySensors.first(where:{$0.id==sensorID}),directOSCAddress == nil {
                result.directOSCAddress=sensor.address
                result.directOSCArgument=sensor.argument
                result.directOSCEnabled=true
            }
            result.enabled=false
        }
        result.sensorID=nil
        return result
    }
}

enum SceneOSCAddress {
    static func input(scene: String, parameter: String, textured: Bool = false) -> String {
        let source=textured ? "/original" : ""
        let tail=parameter.hasPrefix("trigger.")
            ? "/events/"+String(parameter.dropFirst("trigger.".count))
            : "/parameters/"+parameter
        return "/orbit/scene/"+scene+source+tail
    }
    static func isValid(_ address: String) -> Bool {
        address.hasPrefix("/") && address.utf8.count <= 1024 && address.count > 1
            && !address.unicodeScalars.contains {CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)}
            && !address.contains(where:{"*?[]{}#,\\".contains($0)})
    }
}

enum ParameterInputMode: String, Codable, CaseIterable, Identifiable {
    case continuous, event, threshold
    var id: String { rawValue }
    var label: String {
        switch self { case .continuous:return "연속 제어";case .event:return "이벤트 수신";case .threshold:return "임계값 통과" }
    }
}
enum ParameterOutputMode: String, Codable, CaseIterable, Identifiable {
    case continuous, trigger, event, threshold
    var id: String { rawValue }
    var label: String {
        switch self { case .continuous:return "연속값";case .trigger:return "트리거";case .event:return "영상 이벤트마다";case .threshold:return "영상 값 임계 통과" }
    }
}
struct EventThreshold: Codable, Equatable {
    var level: Double = 0.5
    var hysteresis: Double = 0.05
    var sanitized: Self {
        .init(level:level.isFinite ? min(1,max(0.001,level)) : 0.5,
              hysteresis:hysteresis.isFinite ? min(1,max(0,hysteresis)) : 0.05)
    }
}
struct ParameterEventSettings: Codable, Equatable {
    var threshold = EventThreshold()
    var attack: Double = 0.03
    var hold: Double = 0.08
    var release: Double = 0.7
    var sanitized: Self {
        func duration(_ value: Double, _ fallback: Double) -> Double { value.isFinite ? min(30,max(0,value)) : fallback }
        return .init(threshold:threshold.sanitized,attack:duration(attack,0.03),hold:duration(hold,0.08),release:max(0.03,duration(release,0.7)))
    }
}
/// Hysteresis prevents chatter; packets already above the threshold do not retrigger.
struct ThresholdLatch {
    private var high: Bool?
    mutating func accept(_ value: Double, settings: EventThreshold, fireFirst: Bool = true) -> Bool {
        guard value.isFinite else { return false }
        let threshold = settings.sanitized
        if high == nil { high = value >= threshold.level; return fireFirst && high == true }
        if high == true {
            if value < threshold.level && value <= max(0,threshold.level-threshold.hysteresis) { high=false }
            return false
        }
        if value >= threshold.level { high=true;return true }
        return false
    }
}
/// Transient envelopes are never persisted. A new event restarts the attack, including identical OSC packets.
struct ParameterEvents {
    private struct Envelope { var started: Double; var idle: Double; var peak: Double; var settings: ParameterEventSettings; var route: ParameterInputRoute }
    private var envelopes: [String:Envelope] = [:]
    private var latches: [String:ThresholdLatch] = [:]
    private var inputs: [String:ParameterInputRoute] = [:]
    private(set) var counts: [String:Int] = [:]
    mutating func reset() { envelopes.removeAll();latches.removeAll();inputs.removeAll();counts.removeAll() }
    mutating func clear(_ key: String) { envelopes.removeValue(forKey:key);latches.removeValue(forKey:key);inputs.removeValue(forKey:key) }
    mutating func accepts(_ key: String, value: Double, route: ParameterInputRoute, fireFirst: Bool = true) -> Bool {
        if inputs[key] != route { clear(key);inputs[key]=route }
        guard route.enabled, value.isFinite else { return false }
        switch route.behavior {
        case .continuous:return false
        case .event:return value >= 0.5
        case .threshold:return latches[key,default:ThresholdLatch()].accept(value,settings:route.eventSettings.threshold,fireFirst:fireFirst)
        }
    }
    func idleValue(for key: String) -> Double? { envelopes[key]?.idle }
    mutating func fire(_ key: String, route: ParameterInputRoute, at time: Double, idle: Double? = nil, peak: Double? = nil) {
        if inputs[key] != route { clear(key);inputs[key]=route }
        envelopes[key] = Envelope(started:time,idle:idle ?? route.minimum,peak:peak ?? route.maximum,settings:route.eventSettings,route:route)
        counts[key,default:0] += 1
    }
    mutating func apply(_ values: [String:Double], routes: [String:ParameterRoute], specs: [ParameterSpec], at time: Double) -> [String:Double] {
        var result=values
        for spec in specs where !spec.outputOnly {
            let route=routes[spec.id]?.input ?? ParameterInputRoute()
            if let old=inputs[spec.id],old != route { clear(spec.id) }
            if route.behavior != .continuous { result[spec.id]=spec.clamp(route.minimum) }
            guard let envelope=envelopes[spec.id] else { continue }
            guard envelope.route == route else { envelopes.removeValue(forKey:spec.id);continue }
            let age=max(0,time-envelope.started), settings=envelope.settings
            let amount: Double
            if age < settings.attack { amount=age/max(settings.attack,0.000001) }
            else if age < settings.attack+settings.hold { amount=1 }
            else { amount=max(0,1-(age-settings.attack-settings.hold)/settings.release) }
            // A manual cue over a continuous input releases toward the latest live value.
            let returning = route.behavior == .continuous && age >= settings.attack+settings.hold
            let idle = returning ? (values[spec.id] ?? envelope.idle) : envelope.idle
            // Smooth ends avoid abrupt changes in light; switches retain their 0.5 threshold.
            let smooth=amount*amount*(3-2*amount)
            result[spec.id]=spec.clamp(idle+(envelope.peak-idle)*smooth)
            if age >= settings.attack+settings.hold+settings.release { envelopes.removeValue(forKey:spec.id) }
        }
        return result
    }
}

struct SceneTrigger: Identifiable {
    static let addLineID = "trigger.addLine"
    static let departureID = "trigger.departure"
    static let breakthroughID = "trigger.breakthrough"
    static let completionID = "trigger.completion"
    let id: String
    let title: String
    let detail: String
    var offsets: [String:Double] = [:]
    var targets: [String:Double] = [:]
    var reverse: [String] = []
    var brightnessBoost: Double = 0
    var cc: Int = 96
    var spec: ParameterSpec { .init(id:id,title:title,detail:detail,defaultCC:cc,eventOutput:true,isTrigger:true) }
    static func catalog(scene: String, textured: Bool = false) -> [SceneTrigger] {
        if textured { return [
            .init(id:"trigger.flash",title:"섬광",detail:"원본 영상 위에 한 번 밝은 빛이 지나갑니다.",brightnessBoost:2),
            .init(id:"trigger.fade",title:"순간 소멸",detail:"영상의 빛이 사라졌다 돌아옵니다.",offsets:["coverage":-0.8],cc:97)] }
        return entries[scene] ?? []
    }
    private static let entries: [String:[SceneTrigger]] = {
        let data: [String:[SceneTrigger]] = [
            "01_chroma_flow":[
                .init(id:"trigger.sheenFlash",title:"반사광 섬광",detail:"반사광이 한 번 강하게 번집니다.",offsets:["sheen":0.6,"ridgeWidth":0.25],brightnessBoost:2),
                .init(id:"trigger.fluidImpact",title:"유체 충격",detail:"유체 표면을 뒤틀었다 원래 흐름으로 복귀합니다.",offsets:["flowDistortion":0.6,"foldDensity":0.3]),
                .init(id:"trigger.surfaceCompression",title:"표면 압축",detail:"반사선이 가늘고 촘촘하게 모였다 풀립니다.",offsets:["ridgeWidth":-0.5,"foldDensity":0.4])],
            "02_solar_bands":[
                .init(id:"trigger.bandExpand",title:"밴드 확장",detail:"방사형 밴드가 퍼졌다 돌아옵니다.",offsets:["bandLength":0.6,"bandDensity":-0.35],brightnessBoost:0.5),
                .init(id:"trigger.bandIgnite",title:"밴드 점화",detail:"밴드의 빛이 한 번 점화됩니다.",offsets:["bandSharpness":-0.3,"colorSpread":0.3],brightnessBoost:2),
                .init(id:"trigger.bandContract",title:"밴드 수축",detail:"밴드가 짧아지고 밀집했다 풀립니다.",offsets:["bandLength":-0.7,"bandDensity":0.4])],
            "03_aurora_ribbon":[
                .init(id:"trigger.auroraIgnite",title:"오로라 점화",detail:"리본 가장자리와 입자가 한 번 빛납니다.",offsets:["edgeGlow":0.7,"sparkleStrength":0.6],brightnessBoost:1.5),
                .init(id:"trigger.ribbonContract",title:"리본 수축",detail:"리본이 가늘게 모이며 금빛이 잦아들었다 복귀합니다.",offsets:["ribbonWidth":-0.7,"warmLobes":-0.5]),
                .init(id:"trigger.dustBurst",title:"입자 폭발",detail:"미세 입자가 잠깐 밀집해 반짝입니다.",offsets:["dustDensity":0.7,"sparkleStrength":0.8],brightnessBoost:1)],
            "04_electric_corona":[
                .init(id:"trigger.discharge",title:"방전",detail:"전기 가닥이 길고 굵게 뻗으며 한 번 방전합니다.",offsets:["dischargeIntensity":0.8,"filamentLength":0.4,"filamentWidth":0.3],brightnessBoost:2),
                .init(id:"trigger.coronaFlash",title:"광륜 섬광",detail:"안쪽 광륜이 한 번 강하게 빛납니다.",offsets:["rootGlow":0.8],brightnessBoost:1.5),
                .init(id:"trigger.filamentContract",title:"필라멘트 수축",detail:"전기 가닥이 짧고 촘촘하게 모였다 복귀합니다.",offsets:["filamentLength":-0.6,"filamentDensity":0.4])],
            "05_cyan_halo":[
                .init(id:"trigger.beamExpand",title:"광선 확장",detail:"밝은 구간과 헤일로가 한 번 넓어집니다.",offsets:["beamWidth":0.6,"haloWidth":0.5],brightnessBoost:1),
                .init(id:"trigger.acceleration",title:"가속 충격",detail:"밝은 구간을 좁히며 회전 가속을 한 번 가합니다.",offsets:["acceleration":0.8,"beamWidth":-0.3]),
                .init(id:"trigger.haloFade",title:"소멸 파동",detail:"헤일로 일부가 사라졌다 다시 나타납니다.",offsets:["coverage":-0.7])],
            "07_spectral_fragments":[
                .init(id:"trigger.barBurst",title:"바 폭발",detail:"빛 조각이 길고 촘촘하게 솟았다 복귀합니다.",offsets:["barLength":0.5,"fragmentDensity":0.8,"barWidth":0.3],brightnessBoost:1),
                .init(id:"trigger.spectrumIgnite",title:"스펙트럼 점화",detail:"색 띠와 빛 조각이 한 번 점화됩니다.",offsets:["filmMix":0.7,"fragmentGlow":0.7],brightnessBoost:1.5),
                .init(id:"trigger.fragmentFade",title:"순간 소멸",detail:"빛 조각과 색 띠가 사라졌다 돌아옵니다.",offsets:["coverage":-0.8,"fragmentDensity":-0.6])],
            "08_golden_drift":[
                .init(id:"trigger.particleBurst",title:"입자 폭발",detail:"금빛 입자가 커지고 많아지며 한 번 반짝입니다.",offsets:["particleDensity":0.7,"particleSize":0.4,"sparkleStrength":0.7],brightnessBoost:1),
                .init(id:"trigger.goldenFlash",title:"금빛 섬광",detail:"금빛 머리가 넓어지며 강하게 빛납니다.",offsets:["headGlow":0.6,"headWidth":0.4],brightnessBoost:2),
                .init(id:"trigger.tailFade",title:"꼬리 소멸",detail:"남아 있는 금빛이 사라졌다 돌아옵니다.",offsets:["coverage":-0.7])],
            "09_pulse_orbit":[
                .init(id:departureID,title:"출발",detail:"중력점에서 붉은 띠가 태어나 가속합니다. 약 4.5초 뒤 사라집니다."),
                .init(id:breakthroughID,title:"돌파",detail:"흰 띠 하나가 중력점을 빠져나가며 가속합니다. 약 3.6초 뒤 소멸합니다."),
                .init(id:addLineID,title:"새 궤도",detail:"새 궤도를 붉은 띠가 그립니다. 약 7초 뒤 강조 띠는 사라지고 낮은 밝기의 궤도만 남습니다. 최대 개수 다음에는 기본 3개로 돌아갑니다."),
                .init(id:completionID,title:"완료",detail:"움직이던 띠가 감속하고 중력점으로 모이며 사라집니다. 약 4초간의 마무리입니다.")]

        ]
        return data.mapValues { list in list.enumerated().map { i,entry in var event=entry;event.cc=event.id == addLineID ? 100 : 96+i;return event } }
    }()
    static func converted(routes: [String:ParameterRoute], specs: [ParameterSpec]) -> [SceneTrigger] {
        routes.keys.sorted().compactMap { id in
            let prefix="trigger.parameter."
            guard id.hasPrefix(prefix) else { return nil }
            let key=String(id.dropFirst(prefix.count))
            guard let spec=specs.first(where:{$0.id==key}) else { return nil }
            return .init(id:id,title:spec.title+" 반응",detail:"이전 파라미터 이벤트를 별도 트리거로 옮겼습니다. 연속값과 독립적으로 실행합니다.",targets:[key:spec.normalized(routes[id]?.input.legacyTarget ?? spec.range.upperBound)],cc:99)
        }
    }
    static func renderValues(base: [String:Double], events: [SceneTrigger], levels: [String:Double], specs: [ParameterSpec]) -> [String:Double] {
        var offsets: [String:Double]=[:], boost=0.0
        for event in events {
            let weight=levels[event.id] ?? 0
            guard weight>0 else {continue}
            boost += event.brightnessBoost*weight
            for (key,delta) in event.offsets { offsets[key,default:0] += delta*weight }
            for (key,target) in event.targets {
                guard let spec=specs.first(where:{$0.id==key}) else {continue}
                offsets[key,default:0] += (target-spec.normalized(base[key] ?? 0))*weight
            }
            for key in event.reverse {
                guard let spec=specs.first(where:{$0.id==key}) else {continue}
                offsets[key,default:0] += (1-2*spec.normalized(base[key] ?? 0))*weight
            }
        }
        var result=base
        for (key,offset) in offsets {
            guard let spec=specs.first(where:{$0.id==key}) else {continue}
            result[key]=spec.rawValue(normalized:spec.normalized(base[key] ?? 0)+offset)
        }
        result["brightness"]=(base["brightness"] ?? 1)*(1+boost)
        return result
    }
}

// MIDI is retained only to decode and migrate settings from older installations.
enum ControlTransport: String, Codable {
    case midi, osc
}

/// One network destination for every OSC message; addresses remain per control.
struct OSCOutputDestination: Codable, Equatable {
    var host = "127.0.0.1"
    var port = 9001
    var normalized: Self {.init(host:host.trimmingCharacters(in:.whitespacesAndNewlines),port:port)}
    var label: String {host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"}
    var validationError: String? {
        guard !normalized.host.isEmpty,
              !normalized.host.unicodeScalars.contains(where:{CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)}),
              !normalized.host.contains("/"), !normalized.host.contains("\\") else {return "출력 대상 IP 또는 호스트 이름을 입력하세요. URL은 사용할 수 없습니다."}
        guard (1...65535).contains(port) else {return "출력 UDP 포트는 1–65535 범위입니다."}
        return nil
    }
    func applying(to output: ParameterOutputRoute) -> ParameterOutputRoute {
        var result=output.oscOnly();result.host=normalized.host;result.port=port;return result
    }
    /// Caller orders the current scene first. Prefer enabled legacy OSC routes, then configured ones.
    static func migrated(from outputs: [ParameterOutputRoute]) -> Self {
        let candidates=outputs.filter {$0.transport == .osc && Self(host:$0.host,port:$0.port).validationError == nil}
        let selected=candidates.first {$0.enabled} ?? candidates.first {$0.configured == true || $0.host != "127.0.0.1" || $0.port != 9001}
        return selected.map {Self(host:$0.host,port:$0.port).normalized} ?? .init()
    }
}

struct ParameterOutputRoute: Codable, Equatable {
    var enabled = false
    // Optional fields keep settings saved before the connection list decodable.
    var targetName: String? // Legacy setting only; output labels now use their actual destination.
    var configured: Bool?
    var transport: ControlTransport = .osc
    // Legacy serialized fields; never used to transmit.
    var channel = 1
    var controller = 20
    // Kept for decoding older installations and transport emissions. OrbitModel applies the shared destination.
    var host = "127.0.0.1"
    var port = 9001
    var address = "/orbit/value"
    var minimum: Double = 0
    var maximum: Double = 1
    var mode: ParameterOutputMode?
    var threshold: EventThreshold?
    var behavior: ParameterOutputMode { mode ?? .continuous }
    func sendsEvents(spec: ParameterSpec) -> Bool { spec.eventOutput || behavior != .continuous }
    func sendsTriggerValue(spec: ParameterSpec) -> Bool { spec.isTrigger || spec.id == PulseOrbitOutputs.trigger || behavior == .trigger }
    var endpointLabel: String {
        "\(host):\(port)\(address)"
    }
    var displayName: String {
        address
    }
    func isListed(defaultRoute: ParameterOutputRoute) -> Bool {
        enabled || configured == true || self != defaultRoute
    }
    var destinationKey: String {
        "osc:\(host.trimmingCharacters(in:.whitespaces)):\(port):\(address)"
    }
    func oscOnly() -> Self {
        guard transport == .midi else {return self}
        var result=self;result.transport = .osc
        result.minimum=min(1,max(0,minimum/127));result.maximum=min(1,max(0,maximum/127))
        return result
    }
    var validationError: String? {
        guard transport == .osc else {return "이전 MIDI 설정을 OSC로 변환해야 합니다."}
        guard minimum.isFinite, maximum.isFinite else { return "송신 범위에 유효한 숫자를 입력하세요." }
        guard !host.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              !host.contains(where: { $0.isWhitespace }), (1...65535).contains(port) else { return "대상 IP/호스트와 UDP 포트를 확인하세요." }
        guard address.hasPrefix("/"), address.utf8.count <= 1024,
              !address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            return "OSC 주소는 /로 시작하고 공백 없이 입력하세요."
        }
        guard abs(minimum) <= Double(Float.greatestFiniteMagnitude), abs(maximum) <= Double(Float.greatestFiniteMagnitude) else {
            return "OSC float 범위를 벗어났습니다."
        }
        return nil
    }
    func mappedValue(_ value: Double, spec: ParameterSpec) -> Double? {
        guard validationError == nil, value.isFinite else { return nil }
        let n = spec.normalized(value)
        let result = minimum + n*(maximum-minimum)
        return result
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
        if scene == "09_pulse_orbit", spec.outputOnly {
            route.output.transport = .osc; route.output.maximum = 1
            route.output.address = PulseOrbitOutputs.address(parameter)
        }
        if spec.isTrigger {
            route.input.mode = .event;route.input.minimum=0;route.input.maximum=1
            route.output.mode = .event;route.output.transport = .osc;route.output.maximum=1
            route.output.address="/orbit/\(scene)/events/"+parameter.replacingOccurrences(of:"trigger.",with:"")
        }
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

    mutating func separateTriggerRoutes(scene: String, specs: [ParameterSpec], textured: Bool) {
        var routes=(textured ? textureParameterRoutes : parameterRoutes) ?? [:]
        for key in Array(routes.keys) where !key.hasPrefix("trigger.") {
            guard var old=routes[key],let spec=specs.first(where:{$0.id==key}),!spec.outputOnly else {continue}
            let inputEvent=old.input.behavior != .continuous
            // Only legacy envelope/threshold routes move to separate event controls.
            // A packet-trigger output belongs to its original continuous parameter.
            let outputEvent=old.output.behavior == .event || old.output.behavior == .threshold
            guard inputEvent || outputEvent else {continue}
            let id="trigger.parameter."+key
            var event=ParameterRoute.defaults(scene:scene,parameter:id)
            event.input=old.input;event.input.mode=inputEvent ? old.input.mode : .event
            event.input.legacyTarget=old.input.maximum;event.input.minimum=0;event.input.maximum=1
            if inputEvent {
                if key=="speed" && !textured {speed=Float(old.input.minimum)}
                else {values[(textured ? "texture." : "")+key]=Float(old.input.minimum)}
                old.input=ParameterInputRoute()
            } else {event.input.enabled=false;event.input.sensorID=nil}
            if outputEvent {
                event.output=old.output;event.output.mode = .event
                if old.output.behavior == .threshold {
                    event.input.sourceParameter=key;event.input.enabled=true;event.input.mode = .threshold
                    var settings=event.input.eventSettings;settings.threshold=old.output.threshold ?? .init();event.input.event=settings
                }
                old.output=ParameterRoute.defaults(scene:scene,parameter:key,spec:spec).output
            }
            if routes[id]==nil {routes[id]=event}
            routes[key]=old
        }
        if textured {textureParameterRoutes=routes} else {parameterRoutes=routes}
    }
    mutating func migrateRoutes(scene: String) {
        if parameterRoutes == nil { parameterRoutes = migrate(mapping,scene:scene) }
        if textureParameterRoutes == nil { textureParameterRoutes = migrate(textureMapping,scene:scene) }
    }
    mutating func migrateOSCOutputs() {
        func convert(_ routes: [String:ParameterRoute]?) -> [String:ParameterRoute]? {
            routes?.mapValues {old in var route=old;route.output=old.output.oscOnly();return route}
        }
        parameterRoutes=convert(parameterRoutes);textureParameterRoutes=convert(textureParameterRoutes)
    }
    mutating func migrateOSCInputs(using legacySensors: [SensorInput]) {
        func convert(_ routes: [String:ParameterRoute]?) -> [String:ParameterRoute]? {
            routes?.mapValues {old in var route=old;route.input=old.input.addressOnly(using:legacySensors);return route}
        }
        parameterRoutes=convert(parameterRoutes);textureParameterRoutes=convert(textureParameterRoutes)
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
                          now: Date, delta: Double, specs: [ParameterSpec] = ParameterSpec.all,
                          directInputs: [String:OSCReceipt] = [:]) -> [String:Double] {
        var result = base
        for spec in specs {
            guard let rawBase = base[spec.id] else { continue }
            let fallback = spec.clamp(rawBase)
            let sensorRoute=routes[spec.id]?.input
            let sensor=sensors.first {$0.id == sensorRoute?.sensorID}
            // Explicit direct commands win until a newer mapped sensor packet arrives.
            if let direct=directInputs[spec.id],sensorRoute?.receivesDirectOSC != false,
               sensorRoute?.enabled != true || sensor?.receivedAt == nil || direct.receivedAt >= sensor!.receivedAt! {
                result[spec.id]=spec.rawValue(normalized:direct.value)
                smoothed.removeValue(forKey:spec.id)
                continue
            }
            guard let route = routes[spec.id]?.input, route.enabled, route.behavior == .continuous else {
                result[spec.id] = fallback; smoothed.removeValue(forKey:spec.id); continue
            }
            var target = fallback
            if let sensor = sensors.first(where: { $0.id == route.sensorID }),
               let value = sensor.value, value.isFinite, let received = sensor.receivedAt,
               now.timeIntervalSince(received) < 90,
               route.minimum.isFinite, route.maximum.isFinite {
                let n = min(1,max(0,value))
                target = spec.clamp(route.minimum+n*(route.maximum-route.minimum))
            }
            let seconds = !spec.isSwitch && route.smoothingSeconds.isFinite ? max(0,route.smoothingSeconds) : 0
            let blend = seconds == 0 ? 1 : 1-exp(-max(0,delta)*3/seconds)
            let prior = smoothed[spec.id] ?? fallback
            let value = prior+(target-prior)*blend
            smoothed[spec.id] = value; result[spec.id] = spec.clamp(value)
        }
        return result
    }
}

enum OSCEncoder {
    static func immediateBundle(_ messages: [Data]) -> Data {
        var data = Data("#bundle\0".utf8)
        data.append(contentsOf:[0,0,0,0,0,0,0,1])
        for message in messages {
            var size = UInt32(message.count).bigEndian
            withUnsafeBytes(of:&size) { data.append(contentsOf:$0) }
            data.append(message)
        }
        return data
    }
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
