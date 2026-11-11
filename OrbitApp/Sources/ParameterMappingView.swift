import SwiftUI

struct MappedParameterSlider: View {
    @ObservedObject var model: OrbitModel
    let key: String
    let title: String
    var range: ClosedRange<Double> = 0...1
    var suffix = ""
    private var value: Binding<Double> {
        Binding(get:{key == "speed" ? Double(model.playbackSpeed) : Double(model.value(key))},
                set:{ if key == "speed" {model.setSpeed(Float($0))} else {model.setValue(key,Float($0))} })
    }
    var body: some View {
        VStack(spacing:4) {
            HStack(spacing:5) {
                Text(title).foregroundStyle(.secondary).lineLimit(1).help(model.parameterSpec(key).detail)
                ParameterRouteButton(model:model,key:key,title:title)
                Spacer(minLength:0)
                Text(String(format:"%.2f",value.wrappedValue)+suffix).monospacedDigit().lineLimit(1)
            }.font(.system(size:11))
            Slider(value:value,in:range).controlSize(.small).accessibilityLabel(title).accessibilityIdentifier("parameter_"+key)
                .disabled(model.route(for:key).input.enabled && model.selectedScene?.testScene == false)
        }.frame(height:38)
    }
}

struct ParameterRouteButton: View {
    @ObservedObject var model: OrbitModel
    let key: String
    let title: String
    @State private var presented = false
    var body: some View {
        let route = model.route(for:key)
        Button { presented.toggle() } label: {
            HStack(spacing:2) {
                Image(systemName:"link").font(.system(size:11,weight:.semibold))
                if route.input.enabled {Circle().fill(Color.green).frame(width:4,height:4)}
                if route.output.enabled {Circle().fill(Color.cyan).frame(width:4,height:4)}
            }.frame(minWidth:20,minHeight:20)
        }.buttonStyle(.plain)
            .foregroundStyle(route.input.enabled || route.output.enabled ? Color.green : Color.secondary)
            .help("\(title) · 입력 / 출력 매핑")
            .accessibilityLabel("\(title) 입력 / 출력 매핑").accessibilityIdentifier("route_"+key)
            .disabled(model.selectedScene?.testScene != false)
            .sheet(isPresented:$presented) {
                ParameterRoutingPopover(model:model,key:key,title:title) {presented=false}
                    .id("\(model.selectedSceneID):\(model.renderStyle):\(key)")
            }
    }
}

struct ParameterRoutingPopover: View {
    @ObservedObject var model: OrbitModel
    let key: String
    let title: String
    var initialTab = 0
    let close: () -> Void
    @State private var tab = 0
    private var route: ParameterRoute { model.route(for:key) }
    private var spec: ParameterSpec { model.parameterSpec(key) }
    private var currentValue: Double { model.parameterValues[key] ?? model.baseParameterValue(key) }
    private var sensor: SensorInput? { model.sensors.first { $0.id == route.input.sensorID } }
    private func input<T>(_ path: WritableKeyPath<ParameterInputRoute,T>) -> Binding<T> {
        Binding(get:{route.input[keyPath:path]},set:{value in model.setRoute(key) {$0.input[keyPath:path]=value}})
    }
    private func output<T>(_ path: WritableKeyPath<ParameterOutputRoute,T>) -> Binding<T> {
        Binding(get:{route.output[keyPath:path]},set:{value in model.setRoute(key) {$0.output[keyPath:path]=value;$0.output.configured=true}})
    }
    var body: some View {
        VStack(alignment:.leading,spacing:13) {
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text(title).font(.system(size:18,weight:.semibold))
                    Text("\(model.selectedScene?.name ?? "") · \(model.usesTexture ? "원본 재생" : "실시간 생성")")
                        .font(.system(size:10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format:"%.3f",currentValue)).font(.system(size:18,design:.monospaced))
            }
            if !spec.detail.isEmpty {
                Text(spec.detail).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Picker("매핑 방향",selection:$tab) {Text("입력 · 센서 → 영상").tag(0);Text("출력 · 영상 → Live").tag(1)}
                .pickerStyle(.segmented).accessibilityIdentifier("routeTab")
            if tab == 0 { inputPanel } else { outputPanel }
            Spacer(minLength:0)
            Divider()
            HStack {
                if tab == 1 {
                    Button("출력 연결 삭제",role:.destructive) {model.clearControlOutput(key);close()}
                        .accessibilityIdentifier("routeDeleteOutput")
                } else {Text("이 파라미터에만 적용 · 자동 저장").font(.system(size:10)).foregroundStyle(.secondary)}
                Spacer(); Button("닫기",action:close).keyboardShortcut(.cancelAction)
            }
        }.padding(18).frame(width:460,height:630).background(Color(white:0.07)).font(.system(size:12))
            .textFieldStyle(.roundedBorder).preferredColorScheme(.dark)
            .onAppear {tab=initialTab}
    }
    private var inputPanel: some View {
        VStack(alignment:.leading,spacing:13) {
            Toggle("센서로 이 파라미터 제어",isOn:input(\.enabled)).accessibilityIdentifier("routeInputEnabled")
            Picker("센서 입력",selection:input(\.sensorID)) {
                Text("센서 선택").tag(Optional<UUID>.none)
                ForEach(model.sensors) { Text($0.name).tag(Optional($0.id)) }
            }.accessibilityIdentifier("routeSensor")
            if let sensor {
                HStack {
                    Text(sensor.address).font(.system(size:10,design:.monospaced)).lineLimit(1)
                    Spacer(); Text(sensor.value.map {String(format:"%.2f",$0)} ?? "대기 중").monospacedDigit()
                }.foregroundStyle(.secondary)
                Text("센서 범위 \(sensor.minimum.formatted()) … \(sensor.maximum.formatted()) → 아래 영상 값으로 변환")
                    .font(.system(size:10)).foregroundStyle(.secondary)
            } else {Text("메인 화면의 ‘입력 센서’에서 추가할 수 있습니다.").font(.system(size:10)).foregroundStyle(.secondary)}
            HStack(spacing:14) {
                field("영상 최소",value:input(\.minimum),id:"routeInputMin")
                field("영상 최대",value:input(\.maximum),id:"routeInputMax")
            }
            Text("허용 범위 \(spec.range.lowerBound.formatted()) … \(spec.range.upperBound.formatted()) · 최소 > 최대이면 반대로 반응")
                .font(.system(size:10)).foregroundStyle(.secondary)
            VStack(spacing:5) {
                HStack {Text("부드럽게 전환");Spacer();Text(String(format:"%.1f s",route.input.smoothingSeconds)).monospacedDigit()}
                Slider(value:input(\.smoothingSeconds),in:0...30).controlSize(.small).accessibilityIdentifier("routeSmoothing")
            }
            HStack {
                Text("수신 없을 때 기본값")
                TextField("기본값",value:Binding(get:{model.baseParameterValue(key)},set:{v in
                    let value = Float(spec.clamp(v)); if key == "speed" {model.setSpeed(value)} else {model.setValue(key,value)}
                }),format:.number).frame(width:85)
            }
            Text("90초 동안 수신이 없거나 입력이 삭제되면 기본값으로 돌아갑니다. 녹색 점은 입력 매핑, 파란 점은 출력 매핑입니다.")
                .font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if route.input.enabled && !model.oscRunning {
                Button("OSC 수신 시작") {model.startOSC()}.accessibilityIdentifier("routeStartInput")
            }
        }
    }
    private var outputPanel: some View {
        VStack(alignment:.leading,spacing:11) {
            Toggle("이 파라미터 송신",isOn:output(\.enabled)).accessibilityIdentifier("routeOutputEnabled")
            VStack(alignment:.leading,spacing:4) {
                Text("제어 대상 이름").font(.system(size:10)).foregroundStyle(.secondary)
                TextField("예: Live · Filter Cutoff",text:Binding(get:{route.output.targetName ?? ""},set:{value in
                    model.setRoute(key) {$0.output.targetName=value;$0.output.configured=true}
                })).accessibilityIdentifier("routeTargetName")
                Text("직접 붙이는 이름입니다. Live의 대상은 MIDI Map에서 연결하세요.").font(.system(size:10)).foregroundStyle(.secondary)
            }
            Picker("전달 방식",selection:Binding(get:{route.output.transport},set:{transport in
                model.setRoute(key) {$0.output.transport=transport;$0.output.minimum=0;$0.output.maximum=transport == .midi ? 127 : 1;$0.output.configured=true}
            })) {ForEach(ControlTransport.allCases) {Text($0.label).tag($0)}}.accessibilityIdentifier("routeTransport")
            if route.output.transport == .midi {
                Text("가상 MIDI 포트: Orbit Control").font(.system(size:11,weight:.medium))
                HStack {
                    Stepper("채널 \(route.output.channel)",value:output(\.channel),in:1...16).accessibilityIdentifier("routeMIDIChannel")
                    Spacer()
                    Stepper("CC \(route.output.controller)",value:output(\.controller),in:0...119).accessibilityIdentifier("routeMIDICC")
                }
            } else {
                HStack {
                    VStack(alignment:.leading,spacing:4) {Text("대상 IP / 호스트").font(.system(size:10));TextField("127.0.0.1",text:output(\.host)).accessibilityIdentifier("routeOSCHost")}
                    VStack(alignment:.leading,spacing:4) {Text("UDP 포트").font(.system(size:10));TextField("9001",value:output(\.port),format:.number.grouping(.never)).accessibilityIdentifier("routeOSCPort")}.frame(width:85)
                }
                TextField("/orbit/value",text:output(\.address)).font(.system(size:11,design:.monospaced)).accessibilityIdentifier("routeOSCAddress")
            }
            HStack(spacing:14) {
                field("송신 최소",value:output(\.minimum),id:"routeOutputMin")
                field("송신 최대",value:output(\.maximum),id:"routeOutputMax")
            }
            HStack {
                Text("영상 값 → 송신 값").foregroundStyle(.secondary)
                Spacer(); Text(route.output.mappedValue(currentValue,spec:spec).map {String(format:"%.3f → %.3f",currentValue,$0)} ?? "설정 확인").monospacedDigit()
            }.font(.system(size:10))
            if let issue = model.outputIssue(for:key) {Text(issue).font(.system(size:10)).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)}
            Divider()
            Toggle("제어 자동 송신 · 모든 활성 파라미터",isOn:$model.controlOutputEnabled).accessibilityIdentifier("routeAutoOutput")
            Button("이 파라미터 신호 보내기") {model.testControlOutput(key)}
                .disabled(model.outputIssue(for:key) != nil).accessibilityIdentifier("routeTestOutput")
            Text(model.controlOutputStatus).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(2)
            Text(route.output.transport == .midi
                 ? "Live에서 Orbit Control 입력의 Remote를 켜세요. 자동 송신을 끄고 MIDI Map에서 노브를 선택한 뒤 위 버튼을 누릅니다. 매핑을 마치면 자동 송신을 켜세요."
                 : "OSC float 1개를 보냅니다. Live에서 사용하려면 Max for Live 등 OSC 수신 장치를 연결하세요. UDP 송신 성공은 상대 수신 확인이 아닙니다.")
                .font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func field(_ title: String, value: Binding<Double>, id: String) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(title).font(.system(size:10)).foregroundStyle(.secondary)
            TextField(title,value:value,format:.number).accessibilityIdentifier(id)
        }
    }
}
