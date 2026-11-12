import Combine
import Foundation

/// Only the small readout views observe this object. A clock/FPS tick must not
/// invalidate the scene controls, sensor lists, or Metal view layout.
final class PlaybackTelemetry: ObservableObject {
    @Published private(set) var seconds: Double = 0
    @Published private(set) var previewFPS: Double?
    @Published private(set) var outputFPS: Double?

    var timeLabel: String {
        let tenths = Int(max(0,seconds)*10)
        return String(format:"%02d:%02d.%d",tenths/600,(tenths/10)%60,tenths%10)
    }
    func updateTime(_ value: Double, force: Bool = false) {
        guard value.isFinite, force || abs(seconds-value) >= 0.1 else { return }
        if seconds != value { seconds = value }
    }
    func updateFPS(preview: Double?, output: Double?) {
        if previewFPS != preview { previewFPS = preview }
        if outputFPS != output { outputFPS = output }
    }
    func resetOutput() {
        if outputFPS != nil { outputFPS = nil }
    }
}
