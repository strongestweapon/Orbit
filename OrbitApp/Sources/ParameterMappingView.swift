import SwiftUI

struct MappedParameterSlider: View {
    @ObservedObject var model: OrbitModel
    let key: String
    let title: String
    private var value: Binding<Double> {
        Binding(get:{model.normalizedParameterValue(key)},set:{model.setNormalizedParameterValue(key,$0)})
    }
    var body: some View {
        VStack(spacing:4) {
            HStack(spacing:5) {
                Text(title).foregroundStyle(.secondary).lineLimit(1).help(model.parameterSpec(key).detail)
                ParameterRouteButton(model:model,key:key,title:title)
                Spacer(minLength:0)
                Text(String(format:"%.2f",value.wrappedValue)).monospacedDigit().lineLimit(1)
            }.font(.system(size:11))
            Slider(value:value,in:0...1).controlSize(.small).accessibilityLabel(title).accessibilityIdentifier("parameter_"+key)
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
        let connected = route.input.enabled || route.output.enabled
        HStack(spacing:4) {
            Button { presented.toggle() } label: {
                HStack(spacing:2) {
                    Image(systemName:"link").font(.system(size:11,weight:.semibold))
                    if route.input.enabled {Circle().fill(Color.white).frame(width:4,height:4)}
                    if route.output.enabled {Circle().fill(Color.white).frame(width:4,height:4)}
                }.frame(minWidth:20,minHeight:20)
                    .padding(.horizontal,2)
                    .background(connected ? orbitAccent : .clear,in:RoundedRectangle(cornerRadius:4))
            }.buttonStyle(.plain)
                .foregroundStyle(connected ? Color.white : Color.secondary)
                .help(model.parameterSpec(key).outputOnly ? "\(title) · 출력 매핑" : "\(title) · 입력 / 출력 매핑")
                .accessibilityLabel(model.parameterSpec(key).outputOnly ? "\(title) 출력 매핑" : "\(title) 입력 / 출력 매핑").accessibilityIdentifier("route_"+key)
                .disabled(model.selectedScene?.testScene != false)
                .sheet(isPresented:$presented) {
                    ParameterRoutingPopover(model:model,key:key,title:title,initialTab:model.parameterSpec(key).outputOnly ? 1 : 0) {presented=false}
                        .id("\(model.selectedSceneID):\(model.renderStyle):\(key)")
                }

        }.fixedSize()
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
    private var eventOutput: Bool { route.output.sendsEvents(spec:spec) }
    private var cueOutput: Bool { spec.isTrigger || key == PulseOrbitOutputs.trigger }
    private var addsLine: Bool {key == SceneTrigger.addLineID}
    private var currentValue: Double { model.controlValue(key) }
    private var sensor: SensorInput? { model.sensors.first { $0.id == route.input.sensorID } }
    private func input<T>(_ path: WritableKeyPath<ParameterInputRoute,T>) -> Binding<T> {
        Binding(get:{route.input[keyPath:path]},set:{value in model.setRoute(key) {$0.input[keyPath:path]=value}})
    }
    private func normalizedInput(_ path: WritableKeyPath<ParameterInputRoute,Double>) -> Binding<Double> {
        Binding(get:{spec.normalized(route.input[keyPath:path])},set:{value in
            model.setRoute(key) { $0.input[keyPath:path]=spec.rawValue(normalized:value) }
        })
    }
    private func output<T>(_ path: WritableKeyPath<ParameterOutputRoute,T>) -> Binding<T> {
        Binding(get:{route.output[keyPath:path]},set:{value in model.setRoute(key) {$0.output[keyPath:path]=value;$0.output.configured=true}})
    }
    private func eventSetting(_ path: WritableKeyPath<ParameterEventSettings,Double>) -> Binding<Double> {
        Binding(get:{route.input.eventSettings[keyPath:path]},set:{value in model.setRoute(key) {
            var event=$0.input.eventSettings;event[keyPath:path]=value;$0.input.event=event.sanitized
        }})
    }
    private func threshold(_ outputSide: Bool, _ path: WritableKeyPath<EventThreshold,Double>) -> Binding<Double> {
        Binding(get:{(outputSide ? route.output.threshold ?? .init() : route.input.eventSettings.threshold)[keyPath:path]},set:{value in model.setRoute(key) {
            if outputSide { var t=$0.output.threshold ?? .init();t[keyPath:path]=value;$0.output.threshold=t.sanitized }
            else { var e=$0.input.eventSettings;e.threshold[keyPath:path]=value;$0.input.event=e.sanitized }
        }})
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
                TimelineView(.periodic(from:.now,by:0.1)) { _ in
                    Text(spec.isTrigger ? "\(model.parameterEventCount(key))회" : String(format:"%.3f",spec.normalized(currentValue))).font(.system(size:18,design:.monospaced))
                }
            }
            if !spec.detail.isEmpty {
                Text(spec.detail).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            if !spec.outputOnly { Picker("매핑 방향",selection:$tab) {Text("입력 · 센서 → 영상").tag(0);Text("출력 · 영상 → Live").tag(1)}
                .pickerStyle(.segmented).accessibilityIdentifier("routeTab") }
            else { Text(spec.eventOutput ? "교차가 발생할 때마다 출력 · 입력 매핑 없음" : "시뮬레이션에서 연속 출력 · 입력 매핑 없음").font(.caption).foregroundStyle(.secondary) }
            if tab == 0 && !spec.outputOnly { inputPanel } else { outputPanel }
            Spacer(minLength:0)
            Divider()
            HStack {
                if tab == 1 {
                    Button("출력 연결 삭제",role:.destructive) {model.clearControlOutput(key);close()}
                        .accessibilityIdentifier("routeDeleteOutput")
                } else {Text("이 파라미터에만 적용 · 자동 저장").font(.system(size:10)).foregroundStyle(.secondary)}
                Spacer(); Button("닫기",action:close).keyboardShortcut(.cancelAction)
            }
        }.padding(18).frame(width:520,height:690).background(Color(white:0.07)).font(.system(size:12))
            .tint(orbitAccent).accentColor(orbitAccent)
            .buttonStyle(OrbitSecondaryButtonStyle())
            .textFieldStyle(.roundedBorder).preferredColorScheme(.dark)
            .onAppear {tab=spec.outputOnly ? 1 : initialTab}
    }
    private var eventSource: Binding<String> {
        Binding(get:{route.input.sourceParameter.map {"parameter:"+$0} ?? route.input.sensorID.map {"sensor:"+$0.uuidString} ?? ""},set:{source in model.setRoute(key) {
            if source.hasPrefix("parameter:") {$0.input.sourceParameter=String(source.dropFirst(10));$0.input.sensorID=nil;$0.input.mode = .threshold}
            else {$0.input.sourceParameter=nil;$0.input.sensorID=UUID(uuidString:String(source.dropFirst(min(7,source.count))))}
        }})
    }
    private var inputPanel: some View {
        VStack(alignment:.leading,spacing:11) {
            if spec.isTrigger {
                Text("트리거 이벤트 · 한 번 실행하는 동작").fontWeight(.semibold)
                Toggle("외부 입력으로 이벤트 실행",isOn:input(\.enabled)).accessibilityIdentifier("routeInputEnabled")
                Picker("입력 원본",selection:eventSource) {
                    Text("선택 안 함").tag("")
                    ForEach(model.sensors) { Text("OSC · "+$0.name).tag("sensor:"+$0.id.uuidString) }
                    ForEach(model.parameterSpecs.filter {!$0.isTrigger && !$0.eventOutput}) { Text("영상 연속값 · "+$0.title).tag("parameter:"+$0.id) }
                }.accessibilityIdentifier("triggerSource")
                if route.input.sourceParameter == nil {
                    Picker("트리거 조건",selection:Binding(get:{route.input.behavior},set:{model.setInputBehavior(key,$0)})) {
                        Text("이벤트 수신마다").tag(ParameterInputMode.event)
                        Text("연속 입력 임계 통과").tag(ParameterInputMode.threshold)
                    }.pickerStyle(.segmented).accessibilityIdentifier("routeInputMode")
                } else {Text("선택한 영상 연속값이 임계값을 넘을 때 실행합니다.").font(.caption).foregroundStyle(.secondary)}
                if let sensor {Text(sensor.address).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)}
                if route.input.behavior == .threshold {
                    HStack {
                        field("임계값",value:threshold(false,\.level),id:"routeInputThreshold")
                        field("재무장 간격",value:threshold(false,\.hysteresis),id:"routeInputHysteresis")
                    }
                    Text("임계값 이상으로 올라갈 때 1회. 임계값 − 간격 이하로 내려가야 다시 실행됩니다.").font(.caption).foregroundStyle(.secondary)
                }
                if addsLine {
                    TimelineView(.periodic(from:.now,by:0.1)) { _ in
                        Text("현재 \(model.pulseLineCount)개 · 기본 3개").fontWeight(.semibold)
                    }
                    Stepper("최대 \(model.pulseLineLimit)개",value:Binding(get:{model.pulseLineLimit},set:{limit in
                        model.setRoute(key) {$0.input.lineLimit=limit}
                    }),in:4...PulseOrbitSimulation.maximumLineCount).accessibilityIdentifier("triggerLineLimit")
                    Text("최대 개수에서 한 번 더 실행하면 3개로 돌아갑니다. 추가한 라인은 유지되며, 처음부터 재생하거나 씬을 다시 선택하면 3개로 시작합니다.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                } else {
                HStack {
                    Text("반응 강도");Slider(value:normalizedInput(\.maximum),in:0...1)
                    Text(String(format:"%.2f",route.input.maximum)).monospacedDigit()
                }.accessibilityIdentifier("triggerStrength")
                HStack {
                    field("시작 · 초",value:eventSetting(\.attack),id:"routeEventAttack")
                    field("유지 · 초",value:eventSetting(\.hold),id:"routeEventHold")
                    field("소멸 · 초",value:eventSetting(\.release),id:"routeEventRelease")
                }
                }
                Button("이벤트 실행") {model.triggerParameter(key)}.accessibilityIdentifier("routeFireEvent")
                Text(route.input.behavior == .threshold
                     ? "버튼을 누르거나 입력값이 임계값을 통과하면 실행합니다. 연속값 슬라이더와 그 출력은 바뀌지 않습니다."
                     : "버튼과 OSC가 같은 이벤트를 실행합니다. Float ≥ 0.5 수신은 매번 실행되며, 연속값 슬라이더와 그 출력은 바뀌지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            } else {
                Text("연속값 · OSC Float 0.0–1.0").fontWeight(.semibold)
                Toggle("센서로 이 연속값 제어",isOn:input(\.enabled)).accessibilityIdentifier("routeInputEnabled")
                Picker("센서 입력",selection:input(\.sensorID)) {
                    Text("센서 선택").tag(Optional<UUID>.none)
                    ForEach(model.sensors) {Text($0.name).tag(Optional($0.id))}
                }.accessibilityIdentifier("routeSensor")
                if let sensor { Text(sensor.address).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary) }
                HStack {
                    field("영상 최소",value:normalizedInput(\.minimum),id:"routeInputMin")
                    field("영상 최대",value:normalizedInput(\.maximum),id:"routeInputMax")
                }
                VStack(spacing:5) {
                    HStack {Text("부드럽게 전환");Spacer();Text(String(format:"%.1f s",route.input.smoothingSeconds)).monospacedDigit()}
                    Slider(value:input(\.smoothingSeconds),in:0...30).accessibilityIdentifier("routeSmoothing")
                }
                HStack {
                    Text("수신 없을 때 기본값")
                    TextField("기본값",value:Binding(get:{spec.normalized(model.baseParameterValue(key))},set:{model.setNormalizedParameterValue(key,$0)}),format:.number.precision(.fractionLength(0...3)))
                        .frame(width:85).accessibilityIdentifier("routeFallbackValue")
                }
                Text("90초 동안 수신이 없으면 기본값으로 돌아갑니다. 일회성 동작은 메인 화면의 ‘트리거 이벤트’에 연결하세요.").font(.caption).foregroundStyle(.secondary)
            }
            if route.input.enabled && route.input.sourceParameter == nil && !model.oscRunning {Button("OSC 수신 시작") {model.startOSC()}.accessibilityIdentifier("routeStartInput")}
        }
    }
    private var outputPanel: some View {
        VStack(alignment:.leading,spacing:11) {
            Toggle(spec.isTrigger ? "이 이벤트 송신" : spec.outputOnly ? "이 신호 송신" : "이 파라미터 송신",isOn:output(\.enabled)).accessibilityIdentifier("routeOutputEnabled")
            Text(eventOutput ? "트리거 출력 · 발생할 때 1회" : "연속 출력 · 현재 값 전달").fontWeight(.semibold)
            VStack(alignment:.leading,spacing:4) {
                Text("제어 대상 이름").font(.system(size:10)).foregroundStyle(.secondary)
                TextField("예: Live · Filter Cutoff",text:Binding(get:{route.output.targetName ?? ""},set:{value in
                    model.setRoute(key) {$0.output.targetName=value;$0.output.configured=true}
                })).accessibilityIdentifier("routeTargetName")
                Text("연결할 Live 장치나 제어 대상의 이름을 붙이세요.").font(.system(size:10)).foregroundStyle(.secondary)
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
            if cueOutput {
                Text(route.output.transport == .midi ? "이벤트마다 MIDI CC 0 → 127 · 대기 중 송신 없음" : "이벤트마다 OSC Float 1.0 한 번 · 대기 중 송신 없음")
                    .font(.caption).foregroundStyle(.secondary)

            } else {
                HStack(spacing:14) {
                    field("송신 최소",value:output(\.minimum),id:"routeOutputMin")
                    field("송신 최대",value:output(\.maximum),id:"routeOutputMax")
                }
                TimelineView(.periodic(from:.now,by:0.1)) { _ in
                    Text(route.output.mappedValue(currentValue,spec:spec).map {String(format:"영상 %.3f → 송신 %.3f",spec.normalized(currentValue),$0)} ?? "설정 확인").monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let issue = model.outputIssue(for:key) {Text(issue).font(.system(size:10)).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)}
            Divider()
            Toggle("제어 자동 송신 · 모든 활성 파라미터",isOn:$model.controlOutputEnabled).accessibilityIdentifier("routeAutoOutput")
            Button(eventOutput ? "이 이벤트 테스트 보내기" : "이 파라미터 신호 보내기") {model.testControlOutput(key)}
                .disabled(model.outputIssue(for:key) != nil).accessibilityIdentifier("routeTestOutput")
            Text(model.controlOutputStatus).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(2)
            Text(route.output.transport == .midi
                 ? (eventOutput ? "Live의 Orbit Control · Remote를 켜고 클립 실행에 MIDI Map하세요. 소리를 한 번만 재생하려면 Live 클립의 Loop를 끄세요." : "Live에서 Orbit Control 입력의 Remote를 켜세요. 자동 송신을 끄고 MIDI Map에서 노브를 선택한 뒤 위 버튼을 누릅니다.")
                 : (eventOutput ? "이벤트 신호는 같은 목적지별 OSC bundle로 보냅니다. Live에는 bundle을 받는 Max for Live 장치 등을 연결하세요. UDP 송신 성공은 상대 수신 확인이 아닙니다." : "OSC float 1개를 보냅니다. Live에서 사용하려면 Max for Live 등 OSC 수신 장치를 연결하세요. UDP 송신 성공은 상대 수신 확인이 아닙니다."))
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

/// Dedicated event commands have their own IDs and mappings, separate from all sliders.
struct SceneTriggerButtons: View {
    @ObservedObject var model: OrbitModel
    @State private var page=0
    private let pageSize=4
    var body: some View {
        HStack(spacing:14) {
            Text("트리거 이벤트").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
            ForEach(Array(model.sceneTriggers.dropFirst(page*pageSize).prefix(pageSize))) { event in
                HStack(spacing:5) {
                    Button {model.triggerParameter(event.id)} label:{
                        Label(event.title,systemImage:"bolt.fill").font(.system(size:11,weight:.semibold))
                            .padding(.horizontal,11).frame(height:30).foregroundStyle(.white)
                            .background(orbitAccent,in:RoundedRectangle(cornerRadius:5))
                    }.buttonStyle(.plain).modifier(AcceptFirstClick())
                        .accessibilityIdentifier("trigger_"+event.id).help(event.detail)
                    ParameterRouteButton(model:model,key:event.id,title:event.title)
                    TimelineView(.periodic(from:.now,by:0.1)) { _ in
                        Circle().fill(model.controlValue(event.id)>0.01 ? Color.white : Color.white.opacity(0.15)).frame(width:5,height:5)
                        Text(event.id == SceneTrigger.addLineID ? "\(model.pulseLineCount)/\(model.pulseLineLimit)" : "\(model.parameterEventCount(event.id))").monospacedDigit().foregroundStyle(.secondary).font(.system(size:10))
                    }
                }
            }
            Spacer(minLength:0)
            if model.sceneTriggers.count>pageSize {
                Button("이전") {page-=1}.disabled(page==0)
                Button("다음") {page+=1}.disabled((page+1)*pageSize>=model.sceneTriggers.count)
            }
        }.frame(height:34).onChange(of:model.selectedSceneID) {_,_ in page=0}
            .onChange(of:model.sceneTriggers.count) {_,count in page=min(page,max(0,(count-1)/pageSize))}
    }
}
struct SceneEventPanel: View {
    @ObservedObject var model: OrbitModel
    let close: () -> Void
    @State private var page=0
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("\(model.selectedScene?.name ?? "") · 트리거 이벤트").font(.title2);Spacer();Button("닫기",action:close).keyboardShortcut(.cancelAction)}
            Text("한 번 실행하는 독립 동작입니다. 연속값 슬라이더의 설정과 출력은 유지됩니다.").foregroundStyle(.secondary)
            ForEach(Array(model.sceneTriggers.dropFirst(page*4).prefix(4))) {event in
                HStack {
                    VStack(alignment:.leading,spacing:5) {
                        Text(event.title).fontWeight(.semibold)
                        Text(event.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("실행") {model.triggerParameter(event.id)}.accessibilityIdentifier("fireEvent_"+event.id)
                    ParameterRouteButton(model:model,key:event.id,title:event.title)
                }.padding(12).frame(height:80).background(Color.white.opacity(0.05),in:RoundedRectangle(cornerRadius:7))
            }
            Spacer()
            HStack {Text("각 연결 버튼에서 이벤트 입력·출력·시간을 설정합니다.").font(.caption).foregroundStyle(.secondary);Spacer();Button("이전"){page-=1}.disabled(page==0);Button("다음"){page+=1}.disabled((page+1)*4>=model.sceneTriggers.count)}
        }.padding(20).frame(width:650,height:570).background(Color(white:0.07)).preferredColorScheme(.dark)
            .tint(orbitAccent).buttonStyle(OrbitSecondaryButtonStyle())
    }
}
