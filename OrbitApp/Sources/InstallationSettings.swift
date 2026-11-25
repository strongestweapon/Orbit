import Foundation

enum PreviewPolicy: String, Codable, CaseIterable, Identifiable {
    case always, hideWhenFullscreen, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .always: return "항상 켜기"
        case .hideWhenFullscreen: return "출력 전체화면에서 끄기"
        case .off: return "끄기"
        }
    }
    func renders(outputOpen: Bool, fullscreen: Bool) -> Bool {
        self == .always || (self == .hideWhenFullscreen && !(outputOpen && fullscreen))
    }
}

struct InstallationSettings: Codable {
    var displayUUID: String?
    var selectedSceneID: String?
    var frameRate: String?
    var previewPolicy: PreviewPolicy?
    var playing: Bool?
    var resumeOnLaunch: Bool?
    var oscReceiving: Bool?
    var controlSending: Bool?
    var outputOpen: Bool?
    var outputFullscreen: Bool?
}

enum RenderViewMode: Float {
    case strip = 0, ring = 1, led = 2
    static func resolved(_ requested: Float, isOutput: Bool) -> Float {
        isOutput ? led.rawValue : requested
    }
}

enum OSCValue {
    static func normalized(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(1, max(0, value))
    }
    // Each received high message is a separate cue, including identical repeats.
    static func triggers(_ value: Double) -> Bool { normalized(value).map { $0 >= 0.5 } ?? false }
}

enum GlobalOSCAction: String, Codable, CaseIterable, Identifiable {
    case scene, next, previous, restart, play, pause
    var id: String { rawValue }
    var label: String {
        switch self {
        case .scene: return "씬 선택 · 처음부터"
        case .next: return "다음 씬"
        case .previous: return "이전 씬"
        case .restart: return "현재 씬 처음부터"
        case .play: return "재생"
        case .pause: return "일시정지"
        }
    }
}

struct GlobalOSCMapping: Identifiable, Codable, Equatable {
    var id = UUID()
    var enabled = true
    var address: String
    var argument = 0
    var action: GlobalOSCAction
    var sceneID: String?
    var triggerMode: ParameterInputMode?
    var threshold: EventThreshold?
    var isValid: Bool {
        address.hasPrefix("/") && address.utf8.count <= 1024 && argument >= 0 && argument < 16
            && !address.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
    func accepts(address: String, values: [Double]) -> Bool {
        enabled && isValid && self.address == address && values.indices.contains(argument)
            && OSCValue.triggers(values[argument])
    }
}

struct OSCReceipt {
    var value: Double
    var receivedAt: Date
    var triggerCount: Int = 0
    var packetCount: Int = 0

    /// A short hold followed by a fade. Repeated identical packets renew it.
    func activityLevel(at date: Date) -> Double {
        let age=date.timeIntervalSince(receivedAt)
        guard age >= 0, age < 1 else {return 0}
        return age < 0.25 ? 1 : (1-age)/0.75
    }
}
