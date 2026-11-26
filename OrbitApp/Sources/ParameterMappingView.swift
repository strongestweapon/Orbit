import SwiftUI

/// Only this small view samples receipts; OSC traffic does not drive a new UI timer
/// or publish per-packet animation state through the renderer's model.
struct ParameterOSCActivity: View {
    let model: OrbitModel
    let key: String
    let title: String
    var body: some View {
        TimelineView(.periodic(from:.now,by:0.05)) { context in
            OSCReceiveLight(receipt:model.latestOSCInput(for:[key]),date:context.date,title:title)
        }.accessibilityIdentifier("oscInputActivity_"+key)
    }
}

struct OSCReceiveLight: View {
    let receipt: OSCReceipt?
    let date: Date
    let title: String
    private var level: Double {receipt?.activityLevel(at:date) ?? 0}
    private var receiptDescription: String {
        guard let receipt else {return title+" · 외부 OSC를 받으면 켜집니다"}
        let value=String(format:"%.3f",receipt.value)
        let time=receipt.receivedAt.formatted(date:.omitted,time:.standard)
        return "\(title) · OSC 수신 \(receipt.packetCount)회 · 최근 \(value) · \(time)"
    }
    var body: some View {
        Circle().fill(level > 0 ? orbitAccent.opacity(0.35+0.65*level) : Color.white.opacity(0.12))
            .overlay(Circle().stroke(Color.white.opacity(level*0.9),lineWidth:1))
            .shadow(color:orbitAccent.opacity(level*0.7),radius:3)
            .frame(width:8,height:8).padding(.horizontal,2).frame(height:14)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(title+" OSC 수신")
            .accessibilityValue(level > 0 ? "수신 중" : "수신 대기")
            .help(receiptDescription)
    }
}

struct MappedParameterSlider: View {
    @ObservedObject var model: OrbitModel
    let key: String
    let title: String
    var fontSize: CGFloat = 11
    var controlHeight: CGFloat = 38
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
            }.font(.system(size:fontSize))
            Slider(value:value,in:0...1).controlSize(.small).accessibilityLabel(title).accessibilityIdentifier("parameter_"+key)
                .disabled(model.route(for:key).input.enabled && model.selectedScene?.testScene == false)
        }.frame(height:controlHeight)
    }
}

struct ParameterRouteButton: View {
    @ObservedObject var model: OrbitModel
    let key: String
    let title: String
    @State private var presented = false
    var body: some View {
        let route = model.route(for:key)
        let inputConfigured = route.input.enabled || (route.input.receivesDirectOSC && route.input.directOSCAddress != nil)
        let connected = inputConfigured || route.output.enabled
        HStack(spacing:4) {
            Button { presented.toggle() } label: {
                HStack(spacing:2) {
                    Image(systemName:"link").font(.system(size:11,weight:.semibold))
                    if inputConfigured {Circle().fill(Color.white).frame(width:4,height:4)}
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
            if !model.parameterSpec(key).outputOnly {
                ParameterOSCActivity(model:model,key:key,title:title)
            }
        }.fixedSize()
    }
}

struct ParameterRoutingPopover: View {
    @ObservedObject var model: OrbitModel
    let key: String
    let title: String
    var initialTab = 0
    var sceneID: String? = nil
    var textured: Bool? = nil
    let close: () -> Void
    @State private var tab = 0
    @State private var showAdditionalInput = false
    private var targetSceneID: String {sceneID ?? model.selectedSceneID}
    private var targetTextured: Bool {textured ?? model.usesTexture}
    private var isLive: Bool {targetSceneID == model.selectedSceneID && targetTextured == model.usesTexture}
    private var specs: [ParameterSpec] {model.specs(for:targetSceneID,textured:targetTextured)}
    private var route: ParameterRoute {model.route(for:key,sceneID:targetSceneID,textured:targetTextured)}
    private var spec: ParameterSpec {model.parameterSpec(key,sceneID:targetSceneID,textured:targetTextured)}
    private var baseValue: Double {model.baseParameterValue(key,sceneID:targetSceneID,textured:targetTextured)}
    private var lineLimit: Int {min(PulseOrbitSimulation.maximumLineCount,max(4,route.input.lineLimit ?? PulseOrbitSimulation.maximumLineCount))}
    private var outputIssue: String? {model.outputIssue(for:key,sceneID:targetSceneID,textured:targetTextured)}
    private func updateRoute(_ update: (inout ParameterRoute) -> Void) {
        model.setRoute(key,sceneID:targetSceneID,textured:targetTextured,update)
    }
    private var eventOutput: Bool { route.output.sendsEvents(spec:spec) }
    private var cueOutput: Bool { route.output.sendsTriggerValue(spec:spec) }
    private var isPulse: Bool {targetSceneID == PulseOrbitSimulation.sceneID && !targetTextured}
    private var outputTiming: String {
        if isPulse && PulseOrbitOutputs.isCrossing(key) {return "자연 발생 교차만 6초에 최대 1회 · 버튼·외부 OSC 트리거는 매번 즉시 송신합니다."}
        if route.output.behavior == .trigger {
            if spec.eventOutput {return "교차마다 OSC Float 1.0 한 번"}
            if spec.outputOnly {return "시뮬레이션 값이 바뀔 때마다 OSC Float 1.0 한 번"}
            return "OSC 수신마다 1.0 한 번 · 같은 값·0.0도 트리거합니다. 직접 값 변경도 1회 송신합니다."
        }
        return cueOutput ? "이벤트마다 OSC Float 1.0 한 번 · 대기 중 송신 없음" : spec.eventOutput ? "사건마다 해당 값을 한 번 송신합니다." : "연속 출력 · 현재 값 전달"
    }
    private var addsLine: Bool {key == SceneTrigger.addLineID}
    private var currentValue: Double {isLive ? model.controlValue(key) : baseValue}
    private func input<T>(_ path: WritableKeyPath<ParameterInputRoute,T>) -> Binding<T> {
        Binding(get:{route.input[keyPath:path]},set:{value in updateRoute {$0.input[keyPath:path]=value}})
    }
    private func normalizedInput(_ path: WritableKeyPath<ParameterInputRoute,Double>) -> Binding<Double> {
        Binding(get:{spec.normalized(route.input[keyPath:path])},set:{value in
            updateRoute { $0.input[keyPath:path]=spec.rawValue(normalized:value) }
        })
    }
    private func output<T>(_ path: WritableKeyPath<ParameterOutputRoute,T>) -> Binding<T> {
        Binding(get:{route.output[keyPath:path]},set:{value in updateRoute {$0.output[keyPath:path]=value;$0.output.configured=true}})
    }
    private func eventSetting(_ path: WritableKeyPath<ParameterEventSettings,Double>) -> Binding<Double> {
        Binding(get:{route.input.eventSettings[keyPath:path]},set:{value in updateRoute {
            var event=$0.input.eventSettings;event[keyPath:path]=value;$0.input.event=event.sanitized
        }})
    }
    private func threshold(_ outputSide: Bool, _ path: WritableKeyPath<EventThreshold,Double>) -> Binding<Double> {
        Binding(get:{(outputSide ? route.output.threshold ?? .init() : route.input.eventSettings.threshold)[keyPath:path]},set:{value in updateRoute {
            if outputSide { var t=$0.output.threshold ?? .init();t[keyPath:path]=value;$0.output.threshold=t.sanitized }
            else { var e=$0.input.eventSettings;e.threshold[keyPath:path]=value;$0.input.event=e.sanitized }
        }})
    }
    private var sheetHeight: CGFloat {
        let desired: CGFloat = tab == 1 || spec.outputOnly ? 540 : spec.isTrigger ? (showAdditionalInput ? 650 : 510) : 350
        let screen=NSApp.keyWindow?.screen ?? NSScreen.main
        return min(desired,(screen?.visibleFrame.height ?? 900)-100)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            sheetHeader.padding(18).fixedSize(horizontal:false,vertical:true)
            Divider()
            ScrollView(.vertical) {
                VStack(alignment:.leading,spacing:14) {
                    if !isLive {
                        Text("이 씬의 매핑만 편집합니다. 송신 테스트는 해당 씬 재생 중에 사용할 수 있습니다.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    if !spec.detail.isEmpty {
                        Text(spec.detail).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    if tab == 0 && !spec.outputOnly { inputPanel } else { outputPanel }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,18).padding(.vertical,14)
            }.accessibilityIdentifier("parameterMappingContent")
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            Divider()
            HStack {
                Text("이 파라미터에만 적용 · 자동 저장").font(.system(size:10)).foregroundStyle(.secondary)
                Spacer(); Button("닫기",action:close).keyboardShortcut(.cancelAction).accessibilityIdentifier("closeParameterMapping")
            }.padding(.horizontal,18).padding(.vertical,12).fixedSize(horizontal:false,vertical:true)
        }.frame(width:570,height:sheetHeight).background(Color(white:0.07)).font(.system(size:12))
            .tint(orbitAccent).accentColor(orbitAccent)
            .buttonStyle(OrbitSecondaryButtonStyle())
            .textFieldStyle(.roundedBorder).preferredColorScheme(.dark)
            .onAppear {tab=spec.outputOnly ? 1 : initialTab;showAdditionalInput=route.input.enabled && route.input.sourceParameter != nil}
    }
    private var sheetHeader: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text(title).font(.system(size:18,weight:.semibold))
                        .accessibilityIdentifier("parameterMappingTitle")
                    Text("\(model.scenes.first {$0.id == targetSceneID}?.name ?? "") · \(targetTextured ? "원본 재생" : "실시간 생성")")
                        .font(.system(size:10)).foregroundStyle(.secondary)
                }
                Spacer()
                TimelineView(.periodic(from:.now,by:0.1)) { _ in
                    Text(!isLive ? "편집 중" : spec.isTrigger ? "\(model.parameterEventCount(key))회" : String(format:"%.3f",spec.normalized(currentValue))).font(.system(size:18,design:.monospaced))
                }
            }
            if !spec.outputOnly { Picker("매핑 방향",selection:$tab) {Text("입력 · OSC → 영상").tag(0);Text("출력 · 영상 → OSC").tag(1)}
                .pickerStyle(.segmented).accessibilityIdentifier("routeTab") }
            else { Text(spec.eventOutput ? "사건에 맞춰 출력 · 입력 매핑 없음" : "시뮬레이션에서 연속 출력 · 입력 매핑 없음").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var eventSource: Binding<String> {
        Binding(get:{route.input.sourceParameter ?? ""},set:{source in updateRoute {
            $0.input.sourceParameter=source.isEmpty ? nil : source
            if source.isEmpty {$0.input.enabled=false}
            $0.input.sensorID=nil;$0.input.mode = .threshold
        }})
    }
    private var inputPanel: some View {
        VStack(alignment:.leading,spacing:11) {
            DirectOSCInputFields(model:model,key:key,sceneID:targetSceneID,textured:targetTextured)
            if spec.isTrigger {
                Text("트리거 이벤트 · 한 번 실행하는 동작").fontWeight(.semibold)
                DisclosureGroup("영상 값으로 자동 실행",isExpanded:$showAdditionalInput) {
                VStack(alignment:.leading,spacing:9) {
                Toggle("영상 값이 임계값을 넘으면 실행",isOn:Binding(get:{route.input.enabled},set:{enabled in
                    updateRoute {
                        if enabled && $0.input.sourceParameter == nil {
                            $0.input.sourceParameter=specs.first {!$0.isTrigger && !$0.eventOutput}?.id
                        }
                        $0.input.enabled=enabled;$0.input.mode = .threshold
                    }
                })).accessibilityIdentifier("routeInputEnabled")
                Picker("입력 원본",selection:eventSource) {
                    Text("선택 안 함").tag("")
                    ForEach(specs.filter {!$0.isTrigger && !$0.eventOutput}) { Text("영상 연속값 · "+$0.title).tag($0.id) }
                }.accessibilityIdentifier("triggerSource")
                Text("선택한 영상 연속값이 임계값을 넘을 때 실행합니다.").font(.caption).foregroundStyle(.secondary)
                if route.input.behavior == .threshold {
                    HStack {
                        field("임계값",value:threshold(false,\.level),id:"routeInputThreshold")
                        field("재무장 간격",value:threshold(false,\.hysteresis),id:"routeInputHysteresis")
                    }
                    Text("임계값 이상으로 올라갈 때 1회. 임계값 − 간격 이하로 내려가야 다시 실행됩니다.").font(.caption).foregroundStyle(.secondary)
                }
                }.padding(.top,6)
                }
                if addsLine {
                    TimelineView(.periodic(from:.now,by:0.1)) { _ in
                        Text(isLive ? "현재 \(model.pulseLineCount)개 · 기본 3개" : "기본 3개 · 현재 재생 중인 씬이 아닙니다").fontWeight(.semibold)
                    }
                    Stepper("최대 \(lineLimit)개",value:Binding(get:{lineLimit},set:{limit in
                        updateRoute {$0.input.lineLimit=limit}
                    }),in:4...PulseOrbitSimulation.maximumLineCount).accessibilityIdentifier("triggerLineLimit")
                    Text("최대 개수에서 한 번 더 실행하면 3개로 돌아갑니다. 밝은 띠는 재생 시간 7초 후 사라지고 희미한 궤도선은 유지됩니다. 처음부터 재생하거나 씬을 다시 선택하면 3개로 시작합니다.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                } else {
                HStack {
                    Text("반응 강도");Slider(value:normalizedInput(\.maximum),in:0...1)
                    Text(String(format:"%.2f",route.input.maximum)).monospacedDigit()
                }.accessibilityIdentifier("triggerStrength")
                if !isPulse { HStack {
                    field("시작 · 초",value:eventSetting(\.attack),id:"routeEventAttack")
                    field("유지 · 초",value:eventSetting(\.hold),id:"routeEventHold")
                    field("소멸 · 초",value:eventSetting(\.release),id:"routeEventRelease")
                }} else {Text("띠의 생성·이동·소멸은 위 연출 설명에 따라 자동으로 진행됩니다.").font(.caption).foregroundStyle(.secondary)}
                }
                Text("직접 실행은 메인 화면의 이벤트 버튼을 사용합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("받은 0.0–1.0 값이 이 영상 파라미터에 적용됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.oscRunning {Text("OSC 연결 확인 필요 · 상단 OSC 매핑에서 포트를 확인하세요.").font(.caption).foregroundStyle(.secondary)}
        }
    }
    private var outputPanel: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:16) {
                Toggle(spec.isTrigger ? "이 이벤트 송신" : spec.outputOnly ? "이 신호 송신" : "이 파라미터 송신",isOn:output(\.enabled)).accessibilityIdentifier("routeOutputEnabled")
                Spacer(minLength:0)
                if spec.supportsOutputMode {
                Picker("출력 방식",selection:Binding(
                    get:{route.output.behavior == .trigger ? ParameterOutputMode.trigger : .continuous},
                    set:{mode in updateRoute {$0.output.mode=mode;$0.output.configured=true}})) {
                        Text("연속값").tag(ParameterOutputMode.continuous)
                        Text("트리거").tag(ParameterOutputMode.trigger)
                    }.pickerStyle(.segmented).frame(width:210).accessibilityIdentifier("routeOutputMode")
                }
            }
            VStack(alignment:.leading,spacing:6) {
                HStack {
                    Text(cueOutput ? "OSC 트리거 · Float 1.0" : "OSC 연속값 · Float").fontWeight(.medium)
                    Spacer()
                    Text(model.oscOutputDestination.label).font(.system(size:11,design:.monospaced))
                }
                Text("공통 목적지 IP·포트는 OSC 매핑에서 설정합니다.").font(.caption).foregroundStyle(.secondary)
                TextField("/orbit/value",text:output(\.address)).font(.system(size:11,design:.monospaced)).accessibilityIdentifier("routeOSCAddress")
            }
            if cueOutput {
                Text(outputTiming).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if route.output.behavior == .trigger {Text("출력 주소는 동일합니다. 대기 중 반복 송신은 없습니다.").font(.caption).foregroundStyle(.secondary)}
            } else {
                if spec.eventOutput {Text(outputTiming).font(.caption).foregroundStyle(.secondary)}
                HStack(spacing:14) {
                    field("송신 최소",value:output(\.minimum),id:"routeOutputMin")
                    field("송신 최대",value:output(\.maximum),id:"routeOutputMax")
                }
                TimelineView(.periodic(from:.now,by:0.1)) { _ in
                    Text(route.output.mappedValue(currentValue,spec:spec).map {String(format:"영상 %.3f → 송신 %.3f",spec.normalized(currentValue),$0)} ?? "설정 확인").monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let issue = outputIssue {Text(issue).font(.system(size:10)).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)}
            Divider()
            HStack(spacing:12) {
                Button("송신 테스트") {model.testControlOutput(key)}
                    .disabled(!isLive || outputIssue != nil).accessibilityIdentifier("routeTestOutput")
                    .help("선택한 값 또는 이벤트를 한 번 전송합니다. 자동 송신 설정은 유지합니다.")
                Text(outputFeedback).font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Text("Live에서는 Max for Live OSC 수신 장치로 받습니다.")
                .font(.system(size:10)).foregroundStyle(.secondary)
                .help(eventOutput ? "이벤트는 OSC bundle로 보냅니다. UDP 송신 성공은 상대 수신 확인이 아닙니다." : "OSC Float 1개를 보냅니다. UDP 송신 성공은 상대 수신 확인이 아닙니다.")
        }
    }
    private var outputFeedback: String {
        guard isLive else {return "이 씬을 선택하면 체크한 출력이 동작합니다."}
        if let delivery=model.controlDelivery(for:key) {
            if let error=delivery.error {return "이 항목 송신 실패 · "+error}
            return String(format:"최근 송신 %.3f · ",delivery.value)+delivery.at.formatted(date:.omitted,time:.standard)
        }
        return route.output.enabled ? (route.output.behavior == .trigger ? "새 입력 대기 · 트리거 출력" : eventOutput ? "이벤트 발생 시 송신" : "현재 영상 값 송신") : "송신 꺼짐 · 송신 테스트는 한 번만 전송합니다."
    }
    private func field(_ title: String, value: Binding<Double>, id: String) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(title).font(.system(size:10)).foregroundStyle(.secondary)
            TextField(title,value:value,format:.number.grouping(.never).precision(.fractionLength(1...6))).accessibilityIdentifier(id)
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
                        Label(event.title,systemImage:"bolt.fill").font(.system(size:model.selectedSceneID == PulseOrbitSimulation.sceneID ? 13 : 11,weight:.semibold))
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
