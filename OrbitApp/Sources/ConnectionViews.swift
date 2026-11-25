import SwiftUI

/// One status line for every OSC input path and actual OSC delivery.
struct OSCStatusStrip: View {
    @ObservedObject var model: OrbitModel

    var body: some View {
        TimelineView(.periodic(from:.now,by:0.25)) { context in
            let receiving = model.oscRunning && model.lastOSCReceivedAt.map {context.date.timeIntervalSince($0)<1} == true
            let delivery = model.lastControlDelivery
            let sending = delivery.map {$0.error == nil && context.date.timeIntervalSince($0.at)<1} == true
            let sendFailure = model.hasActiveControlOutput && delivery?.error != nil
            let receiveLabel = model.oscRunning ? (receiving ? "수신 중" : "수신 대기") : "수신 꺼짐"
            let sendLabel = model.selectedScene?.testScene == true ? "송신 대기 · 테스트 씬"
                : sendFailure ? "송신 실패" : sending ? "송신 중" : model.hasActiveControlOutput ? "송신 대기 · \(model.activeControlOutputCount)개" : "송신 항목 없음"
            HStack(spacing:12) {
                HStack(spacing:5) {
                        Circle().fill(model.oscRunning ? orbitAccent : .gray).frame(width:6,height:6)
                        Text("OSC \(receiveLabel) · \(model.port)").foregroundStyle(.white)
                }.fixedSize().accessibilityElement(children:.combine).accessibilityIdentifier("oscReceiveStatus")
                    .help(model.oscState+" · 앱 실행 시 자동으로 수신합니다.")
                HStack(spacing:5) {
                    Circle().fill(sendFailure ? .orange : (sending || model.hasActiveControlOutput ? orbitAccent : .gray)).frame(width:6,height:6)
                    Text("OSC \(sendLabel)").foregroundStyle(.white)
                }.fixedSize().accessibilityElement(children:.combine).accessibilityIdentifier("controlSendStatus")
                    .help("항목별 송신 체크로 제어합니다. 송신은 이 Mac의 전송 결과입니다.")
                Divider().frame(height:12)
                Text(recentSignal).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .help(recentSignal).accessibilityIdentifier("recentControlSignal")
            }
        }.font(.system(size:10,design:.monospaced))
    }

    private var recentSignal: String {
        if let delivery=model.lastControlDelivery,delivery.at >= (model.lastOSCReceivedAt ?? .distantPast) {
            let label=delivery.error == nil ? "최근 송신" : "송신 실패"
            return "\(label)  \(delivery.signal)  \(String(format:"%.2f",delivery.value))"
                + (delivery.error.map {" · "+$0} ?? "")
        }
        return model.lastOSCReceivedAt == nil ? "최근 신호 없음" : "최근 수신  "+model.lastMessage
    }
}
