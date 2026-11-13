import SwiftUI

enum PlaybackFrameRate: String, CaseIterable, Identifiable {
    case sixty, displayMaximum
    var id: String { rawValue }
    var label: String { self == .sixty ? "60 FPS" : "화면 최대" }
    func target(screenMaximum: Int) -> Int { self == .sixty ? 60 : (screenMaximum > 0 ? screenMaximum : 60) }
}

final class PerformanceMeasurement: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var result: BenchmarkResult?
    @Published private(set) var message = "현재 씬과 조절값으로 측정합니다."
    private var cancellation: BenchmarkCancellation?

    func start(_ request: BenchmarkRequest, finished: @escaping ()->Void) {
        guard !isRunning else { return }
        let token = BenchmarkCancellation(); cancellation = token
        result = nil; progress = 0; message = "GPU 준비 중…"; isRunning = true
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let outcome = Result {
                try RenderBenchmark.run(request,cancellation:token) { progress in
                    DispatchQueue.main.async { [weak self] in
                        self?.progress = progress; self?.message = "제한 없이 측정 중…"
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { finished(); return }
                switch outcome {
                case .success(let result): self.result = result; self.message = "측정 완료"
                case .failure(let error): self.message = error.localizedDescription
                }
                self.isRunning = false; self.cancellation = nil; finished()
            }
        }
    }
    func cancel() { cancellation?.cancel() }
    func failed(_ message: String) { self.message = message }
    deinit { cancellation?.cancel() }
}

struct PerformanceView: View {
    @ObservedObject var model: OrbitModel
    @ObservedObject var measurement: PerformanceMeasurement
    let close: ()->Void
    @State private var resolution: OutputResolution = .uhd
    @State private var includePreviews = true
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Text("FPS · 성능").font(.system(size:20,weight:.semibold))
                Spacer(); Button(action:close) { Image(systemName:"xmark") }.accessibilityLabel("성능 닫기")
            }
            Picker("일반 재생",selection:$model.frameRate) {
                ForEach(PlaybackFrameRate.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).disabled(measurement.isRunning).accessibilityIdentifier("playbackFrameRate")
            Text("화면 최대는 각 모니터가 지원하는 주사율까지 요청합니다. 영상의 움직임 속도는 그대로입니다.")
                .font(.system(size:11)).foregroundStyle(.secondary)
            Divider()
            Text("최대 성능 측정").font(.system(size:15,weight:.semibold))
            HStack {
                Picker("측정 크기",selection:$resolution) {
                    ForEach([OutputResolution.fullHD,.qhd,.uhd]) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("benchmarkResolution")
                Toggle("미리보기 포함",isOn:$includePreviews).accessibilityIdentifier("benchmarkPreviews")
            }.disabled(measurement.isRunning)
            Text("현재 씬을 5초간 속도 제한 없이 그립니다. 측정 중 미리보기는 잠시 고정됩니다. 결과는 화면 주사율과 무관한 렌더 처리량이며 HDMI·LED 표시 FPS는 아닙니다.")
                .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if let result = measurement.result {
                HStack(alignment:.firstTextBaseline,spacing:18) {
                    VStack(alignment:.leading,spacing:4) {
                        Text("제한 없는 평균 처리량").font(.system(size:11)).foregroundStyle(.secondary)
                        Text(String(format:"%.1f FPS",result.framesPerSecond)).font(.system(size:32,weight:.semibold,design:.monospaced))
                            .accessibilityIdentifier("benchmarkFPS")
                    }
                    Spacer()
                    VStack(alignment:.trailing,spacing:5) {
                        Text("GPU 중앙값 · "+milliseconds(result.gpuMedianMS))
                        Text("GPU 95% 지점 · "+milliseconds(result.gpuP95MS))
                    }.font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)
                }
                Text(resultDescription(result))
                    .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            } else {
                VStack(alignment:.leading,spacing:12) {
                    Text(measurement.message).accessibilityIdentifier("benchmarkStatus")
                    if measurement.isRunning { ProgressView(value:measurement.progress) }
                }.frame(maxWidth:.infinity,minHeight:108,alignment:.leading)
            }
            Spacer(minLength:0)
            HStack {
                Text(model.outputOpen ? "출력을 중지한 뒤 측정하세요." : (model.usesTexture ? "실시간 생성 모드에서 측정할 수 있습니다." : "미리보기·창 크기가 바뀌면 결과도 달라집니다."))
                    .font(.system(size:11)).foregroundStyle(.secondary)
                Spacer()
                if measurement.isRunning {
                    Button("측정 중지") { measurement.cancel() }.accessibilityIdentifier("cancelBenchmark")
                } else {
                    Button("5초 측정") { model.startBenchmark(resolution:resolution,includePreviews:includePreviews) }
                        .buttonStyle(.borderedProminent).disabled(model.outputOpen || model.usesTexture)
                        .accessibilityIdentifier("startBenchmark")
                }
            }
        }.padding(22).frame(width:620,height:510).background(Color(white:0.07))
            .onDisappear { measurement.cancel() }
    }
    private func milliseconds(_ value:Double?)->String { value.map {String(format:"%.2f ms",$0)} ?? "—" }
    private func resultDescription(_ result:BenchmarkResult)->String {
        ["\(result.sceneName) · \(result.deviceName)",
         result.surfaces.map { "\($0.name) \($0.width)×\($0.height)" }.joined(separator:" · "),
         String(format:"%d 프레임 완료 / %.2f초 · 준비 시간 제외",result.frames,result.elapsedSeconds)].joined(separator:"\n")
    }
}
