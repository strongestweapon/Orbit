import SwiftUI

struct MappingRow: Identifiable {
    var id: String
    var title: String
    var scope: String
    var address: String
    var active: Bool
    var value: Double?
    var globalID: UUID?
    var sceneID: String?
    var textured = false
    var spec: ParameterSpec?
    var route: ParameterRoute?
    var configured = false
    var searchText = ""
    var sortAddress = ""
    var globalRoute: GlobalOSCMapping?
    var isEvent: Bool {globalID != nil || spec?.isTrigger == true || spec?.eventOutput == true}
    /// A continuous input may produce trigger output; either side can match a filter.
    func matchesSignalType(_ filter: Int) -> Bool {
        guard filter != 0 else {return true}
        let inputEvent = globalID != nil || spec?.isTrigger == true
        let hasInput = spec?.outputOnly != true
        let outputEvent = spec.map {route?.output.sendsEvents(spec:$0) ?? false} ?? false
        let hasOutput = route != nil
        return filter == 1 ? (hasInput && !inputEvent || hasOutput && !outputEvent)
            : (hasInput && inputEvent || hasOutput && outputEvent)
    }

    private static func number(_ value: Double, integer: Bool = false) -> String {
        value.formatted(.number.locale(Locale(identifier:"en_US_POSIX"))
            .grouping(.never).precision(.fractionLength(integer ? 0...0 : 1...6)))
    }
    private static func thresholdLabel(_ settings: EventThreshold) -> String {
        let threshold=settings.sanitized
        let reset=max(0,threshold.level-threshold.hysteresis)
        // With zero hysteresis the latch still requires a value strictly below the threshold.
        let resetCondition=threshold.hysteresis == 0 ? "< \(number(threshold.level))" : "≤ \(number(reset))"
        return "≥ \(number(threshold.level)) 진입 시 1회\n\(resetCondition) 이후 다시 진입하면 반복"
    }
    var inputRangeLabel: String {
        if spec?.outputOnly == true {return "외부 입력 없음"}
        if route?.input.sourceParameter != nil && route?.input.enabled == true {return "영상 연속값 0.0–1.0"}
        return "OSC Float 0.0–1.0"
    }
    var conditionLabel: String {
        if let global=globalRoute {
            return global.triggerMode == .threshold ? Self.thresholdLabel(global.threshold ?? .init()) : "≥ 0.5 수신마다 1회"
        }
        guard let spec,let route else {return ""}
        if spec.outputOnly {return spec.eventOutput ? "실제 교차가 발생할 때마다 1회" : "시뮬레이션 연속값 0.0–1.0"}
        if spec.isTrigger {
            let extra=route.input.behavior == .threshold ? Self.thresholdLabel(route.input.eventSettings.threshold) : "≥ 0.5 수신마다 1회"
            if route.input.receivesDirectOSC && route.input.enabled && route.input.sourceParameter != nil && route.input.behavior == .threshold {return "직접 ≥ 0.5 수신마다 1회\n영상 값: "+extra}
            return route.input.receivesDirectOSC ? "≥ 0.5 수신마다 1회" : extra
        }
        return "0.0 → 1.0"
    }
    var outputRangeLabel: String? {
        guard let spec,let route else {return nil}
        let output=route.output
        let cue=output.sendsTriggerValue(spec:spec)
        let range=cue ? "1.0"
            : "\(Self.number(output.minimum)) → \(Self.number(output.maximum))"
        let timing=output.behavior == .trigger
            ? (spec.outputOnly ? (spec.eventOutput ? "교차마다 트리거" : "값 변경마다 트리거") : "입력마다 트리거")
            : output.sendsEvents(spec:spec) ? "1회" : "연속"
        return "OSC Float \(range) · \(timing)"+(output.enabled ? "" : " (꺼짐)")
    }
}

extension OrbitModel {
    /// Project the current control catalog, including commands never configured by the operator.
    /// Saved routes supply connections; they do not define which controls exist.
    var mappingRows: [MappingRow] {
        var result=globalOSC.map { route in
            MappingRow(id:route.id.uuidString,
                title:route.action == .scene ? (scenes.first {$0.id == route.sceneID}?.name ?? "씬 선택") : route.action.label,
                scope:route.triggerMode == .threshold ? "글로벌 · 임계값 통과" : "글로벌 · 수신마다 트리거",
                address:route.address,active:route.enabled,value:globalReceipts[route.id]?.value,globalID:route.id,configured:true,sortAddress:route.address,globalRoute:route)
        }
        for scene in scenes where !scene.testScene {
            for textured in (scene.texture == nil ? [false] : [false,true]) {
                let catalog=specs(for:scene.id,textured:textured)
                let savedRoutes=(textured ? settings[scene.id]?.textureParameterRoutes : settings[scene.id]?.parameterRoutes) ?? [:]
                let ordered=catalog.filter(\.isTrigger)+catalog.filter {!$0.isTrigger}
                let active=selectedSceneID == scene.id && usesTexture == textured
                for spec in ordered {
                    let defaults=effectiveRoute(ParameterRoute.defaults(scene:scene.id,parameter:spec.id,spec:spec))
                    let route=effectiveRoute(savedRoutes[spec.id] ?? defaults)
                    let source=route.input.enabled ? route.input.sourceParameter.map {key in catalog.first {$0.id==key}?.title ?? key} : nil
                    let configured=route.input.enabled && route.input.sourceParameter != nil || route.output.isListed(defaultRoute:defaults.output)
                    let direct=inputOSCAddress(spec.id,sceneID:scene.id,textured:textured)
                    let address=spec.outputOnly ? route.output.address : direct+(source.map {"\n영상 값: "+$0} ?? "")
                    result.append(MappingRow(id:"\(scene.id):\(textured):\(spec.id)",title:spec.title,
                        scope:scene.name+" · "+(textured ? "원본" : "실시간")+" · "+(spec.isTrigger || spec.eventOutput ? "트리거" : "연속값"),
                        address:address,active:active,value:active ? directOSCReceipts[spec.id]?.value : nil,sceneID:scene.id,textured:textured,spec:spec,route:route,configured:configured || route.input.directOSCAddress != nil || route.input.directOSCEnabled != nil,
                        searchText:[spec.id,route.output.endpointLabel].joined(separator:" "),
                        sortAddress:spec.outputOnly ? route.output.address : direct))
                }
            }
        }
        return result.sorted { left,right in
            if (left.globalID != nil) != (right.globalID != nil) {return left.globalID != nil}
            if left.globalID != nil {
                let sceneActions:[GlobalOSCAction]=[.scene,.next,.previous]
                let leftScene=left.globalRoute.map {sceneActions.contains($0.action)} ?? false
                let rightScene=right.globalRoute.map {sceneActions.contains($0.action)} ?? false
                if leftScene != rightScene {return leftScene}
            } else {
                if left.sceneID != right.sceneID {return (left.sceneID ?? "").localizedStandardCompare(right.sceneID ?? "") == .orderedAscending}
                if left.textured != right.textured {return !left.textured}
            }
            let order=left.sortAddress.localizedStandardCompare(right.sortAddress)
            return order == .orderedSame ? left.id < right.id : order == .orderedAscending
        }
    }
}

/// One surface for input and output. Common edits never open another sheet.
struct OSCMappingView: View {
    @ObservedObject var model: OrbitModel
    let close: () -> Void
    @State private var scope = 0
    @State private var signalType = 0
    @State private var sceneFilter = ""
    @State private var search = ""
    @State private var sourceFilter = 0
    @State private var receivePort = ""
    @State private var outputHost = ""
    @State private var outputPort = ""
    private var proposedOutput: OSCOutputDestination {.init(host:outputHost,port:Int(outputPort.trimmingCharacters(in:.whitespacesAndNewlines)) ?? 0)}
    private var networkIssue: String? {
        guard let number=UInt16(receivePort.trimmingCharacters(in:.whitespacesAndNewlines)),number>0 else {return "수신 UDP 포트는 1–65535 범위입니다."}
        return proposedOutput.validationError
    }
    private var networkChanged: Bool {receivePort != model.port || proposedOutput.normalized != model.oscOutputDestination}
    private var visibleScreen: NSRect {(NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x:0,y:0,width:1440,height:900)}
    private func loadNetworkSettings() {
        receivePort=model.port;outputHost=model.oscOutputDestination.host;outputPort=String(model.oscOutputDestination.port)
    }
    private func applyNetworkSettings() {
        if model.applyOSCNetworkSettings(receivePort:receivePort,output:proposedOutput) {loadNetworkSettings()}
    }
    private var rows: [MappingRow] {
        let query=search.trimmingCharacters(in:.whitespacesAndNewlines)
        return model.mappingRows.filter { row in
            row.matchesSignalType(signalType)
            && (scope == 0 || (scope == 1 ? row.globalID != nil : row.sceneID == (sceneFilter.isEmpty ? model.selectedSceneID : sceneFilter)))
            && (sourceFilter == 0 || row.globalID != nil || row.textured == (sourceFilter == 2))
            && (query.isEmpty || [row.title,row.scope,row.address,row.searchText].joined(separator:" ").localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(spacing:14) {
            HStack(spacing:12) {
                Text("OSC 전체 맵").font(.system(size:21,weight:.semibold))
                Text("수신·송신 주소와 상태를 한눈에 확인합니다").foregroundStyle(.secondary)
                Spacer()
                Button("닫기",action:close).keyboardShortcut(.cancelAction)
            }
            networkHeader
            filters
            HStack(alignment:.top,spacing:16) {
                signalPane(output:false).frame(minWidth:0,maxWidth:.infinity)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width:1)
                signalPane(output:true).frame(minWidth:0,maxWidth:.infinity)
            }
            HStack {
                Text("주소는 Enter 또는 다른 항목 선택 시 저장 · 나머지 설정은 자동 저장")
                Spacer()
                Text("송신 표시는 이 Mac의 전송 결과입니다.")
                    .help("UDP는 상대 장치의 수신 여부를 확인하지 않습니다.")
            }.font(.system(size:11)).foregroundStyle(.secondary)
        }.padding(20)
            .frame(width:min(1200,visibleScreen.width-60),height:min(860,visibleScreen.height-80))
            .background(Color(white:0.055)).font(.system(size:13))
            .tint(orbitAccent).buttonStyle(OrbitSecondaryButtonStyle())
            .textFieldStyle(.roundedBorder)
            .onAppear {loadNetworkSettings()}
    }
    private func signalPane(output: Bool) -> some View {
        let entries=rows.filter {output ? $0.globalID == nil : $0.spec?.outputOnly != true}
        return VStack(alignment:.leading,spacing:8) {
            HStack {
                Text(output ? "송신 주소" : "수신 주소").fontWeight(.medium)
                Text("\(entries.count)개").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text(output ? "최근 송신" : "최근 수신").foregroundStyle(.secondary)
            }.font(.system(size:12)).padding(.horizontal,4)
            ScrollViewReader {proxy in
                ScrollView {
                    LazyVStack(spacing:8) {
                        ForEach(entries) {row in
                            OSCMappingCard(model:model,row:row,outputSide:output).id(row.id)
                        }
                        if entries.isEmpty {
                            VStack(spacing:12) {
                                Image(systemName:output ? "arrow.up.right" : "arrow.down.left").font(.system(size:22))
                                Text(output && scope == 1 ? "글로벌 OSC 출력 없음" : "조건에 맞는 신호 없음").fontWeight(.medium)
                                Text(output && scope == 1 ? "씬 선택·재생 같은 글로벌 동작은 입력만 받습니다." : "검색이나 필터를 변경하세요.")
                                    .font(.system(size:12)).multilineTextAlignment(.center)
                            }.foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(.vertical,48)
                        }
                    }.padding(.trailing,2)
                }.accessibilityIdentifier(output ? "mappingOutputList" : "mappingInputList")
                    .onChange(of:scope) {_,_ in if let first=entries.first {proxy.scrollTo(first.id,anchor:.top)}}
                    .onChange(of:signalType) {_,_ in if let first=entries.first {proxy.scrollTo(first.id,anchor:.top)}}
                    .onChange(of:sceneFilter) {_,_ in if let first=entries.first {proxy.scrollTo(first.id,anchor:.top)}}
                    .onChange(of:sourceFilter) {_,_ in if let first=entries.first {proxy.scrollTo(first.id,anchor:.top)}}
                    .onChange(of:search) {_,_ in if let first=entries.first {proxy.scrollTo(first.id,anchor:.top)}}
            }
        }
    }
    private var networkHeader: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(alignment:.top,spacing:16) {
                VStack(alignment:.leading,spacing:10) {
                    HStack {
                        Label("입력",systemImage:"arrow.down.left").font(.system(size:16,weight:.semibold))
                        Text("외부 → 영상").foregroundStyle(.secondary)
                        Spacer()
                        Text(model.oscRunning ? "수신 중" : "연결 확인 필요").font(.system(size:12))
                            .foregroundStyle(model.oscRunning ? Color.secondary : .orange)
                    }
                    HStack(alignment:.bottom,spacing:16) {
                        OSCLocalAddressView()
                        VStack(alignment:.leading,spacing:4) {
                            Text("수신 UDP 포트").font(.system(size:11)).foregroundStyle(.secondary)
                            TextField("9000",text:$receivePort).frame(width:96).accessibilityIdentifier("oscReceivePort")
                        }
                        Spacer(minLength:0)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width:1)
                VStack(alignment:.leading,spacing:10) {
                    HStack {
                        Label("출력",systemImage:"arrow.up.right").font(.system(size:16,weight:.semibold))
                        Text("영상 → OSC").foregroundStyle(.secondary)
                        Spacer()
                        Text("모든 씬 공통 목적지").font(.system(size:11)).foregroundStyle(.secondary)
                    }
                    HStack(alignment:.bottom,spacing:10) {
                        VStack(alignment:.leading,spacing:4) {
                            Text("대상 IP / 호스트").font(.system(size:11)).foregroundStyle(.secondary)
                            TextField("127.0.0.1",text:$outputHost).accessibilityIdentifier("oscOutputHost")
                        }
                        VStack(alignment:.leading,spacing:4) {
                            Text("출력 UDP 포트").font(.system(size:11)).foregroundStyle(.secondary)
                            TextField("9001",text:$outputPort).frame(width:86).accessibilityIdentifier("oscOutputPort")
                        }
                        Button(networkChanged || model.oscRunning ? "적용" : "다시 연결",action:applyNetworkSettings)
                            .disabled((!networkChanged && model.oscRunning) || networkIssue != nil)
                            .accessibilityIdentifier("applyOSCNetwork")
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.fixedSize(horizontal:false,vertical:true).padding(14)
                .background(Color.white.opacity(0.045),in:RoundedRectangle(cornerRadius:10))
                .onSubmit {if networkIssue == nil && (networkChanged || !model.oscRunning) {applyNetworkSettings()}}
            if networkChanged,let issue=networkIssue {Text(issue).font(.caption).foregroundStyle(.orange)}
            if !model.oscRunning {Text(model.oscState).font(.caption).foregroundStyle(.orange)}
        }
    }
    private var filters: some View {
        VStack(spacing:10) {
            HStack(spacing:12) {
                Picker("범위",selection:$scope) {Text("전체").tag(0);Text("글로벌").tag(1);Text("영상별").tag(2)}
                    .pickerStyle(.segmented).frame(width:270).accessibilityIdentifier("mappingScope")
                if scope == 2 {
                    Picker("영상",selection:$sceneFilter) {
                        Text("현재 씬").tag("")
                        ForEach(model.scenes.filter {!$0.testScene}) {Text($0.name).tag($0.id)}
                    }.frame(maxWidth:240).accessibilityIdentifier("mappingScene")
                }
                Spacer(minLength:0)
                Picker("영상 소스",selection:$sourceFilter) {
                    Text("모든 방식").tag(0);Text("실시간 생성").tag(1);Text("원본 재생").tag(2)
                }.frame(width:215).accessibilityIdentifier("mappingSource").disabled(scope == 1)
            }
            HStack(spacing:12) {
                Picker("종류",selection:$signalType) {Text("모든 신호").tag(0);Text("연속값").tag(1);Text("트리거").tag(2)}
                    .pickerStyle(.segmented).frame(width:270).accessibilityIdentifier("mappingSignalType")
                TextField("파라미터·동작·씬·입출력 주소 검색",text:$search).accessibilityIdentifier("mappingSearch")
                Text("\(rows.count)개").monospacedDigit().foregroundStyle(.secondary).frame(minWidth:44,alignment:.trailing)
            }
        }
    }
}

/// Both lists use the same control catalog and route setters as the main parameter buttons.
private struct OSCMappingCard: View {
    @ObservedObject var model: OrbitModel
    let row: MappingRow
    let outputSide: Bool
    private var key: String {row.spec?.id ?? ""}
    private var scene: String {row.sceneID ?? ""}
    private var globalIndex: Int? {model.globalOSC.firstIndex {$0.id == row.globalID}}
    private var currentRoute: ParameterRoute {model.route(for:key,sceneID:scene,textured:row.textured)}
    private func update(_ change: (inout ParameterRoute)->Void) {model.setRoute(key,sceneID:scene,textured:row.textured,change)}
    private var inputEnabled: Binding<Bool> {
        Binding(get:{globalIndex.map {model.globalOSC[$0].enabled} ?? currentRoute.input.receivesDirectOSC},set:{value in
            if let i=globalIndex {model.globalOSC[i].enabled=value}
            else {update {$0.input.directOSCEnabled=value}}
        })
    }
    private var inputAddress: Binding<String> {
        Binding(get:{globalIndex.map {model.globalOSC[$0].address} ?? model.inputOSCAddress(key,sceneID:scene,textured:row.textured)},set:{value in
            if let i=globalIndex {model.globalOSC[i].address=value}
            else {update {$0.input.directOSCAddress=value}}
        })
    }
    private func output<T>(_ path: WritableKeyPath<ParameterOutputRoute,T>) -> Binding<T> {
        Binding(get:{currentRoute.output[keyPath:path]},set:{value in update {$0.output[keyPath:path]=value;$0.output.configured=true}})
    }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:10) {
                Text(row.title).font(.system(size:13,weight:.semibold))
                Text(row.scope).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength:0)
                if row.globalID == nil {
                    Text(row.active ? "현재 씬" : "대기 씬").font(.system(size:11)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal,12).padding(.vertical,8).background(Color.white.opacity(0.025))
            Group {
                if outputSide {outputCell} else {inputCell}
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
        }.background(Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
            .clipShape(RoundedRectangle(cornerRadius:8))
            .accessibilityIdentifier((outputSide ? "mappingOutput_" : "mappingInput_")+row.id)
    }

    @ViewBuilder private var inputCell: some View {
        if row.spec?.outputOnly == true {
            VStack(alignment:.leading,spacing:8) {
                Text("입력 없음").foregroundStyle(.secondary)
                Text(row.conditionLabel).font(.system(size:11)).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,minHeight:88,alignment:.leading)
        } else {
            VStack(alignment:.leading,spacing:8) {
                HStack {
                    Toggle("수신",isOn:inputEnabled).toggleStyle(.checkbox).accessibilityIdentifier("mapInputEnabled_"+row.id)
                    Spacer()
                    MappingReceiveStatus(model:model,row:row)
                }
                OSCMapAddressField(value:inputAddress,identifier:"mapInputAddress_"+row.id)
                HStack(spacing:8) {
                    Text("Float 0.0–1.0").foregroundStyle(.secondary)
                    if row.globalID != nil || row.spec?.isTrigger == true {
                        Text(row.conditionLabel).lineLimit(2).help(row.conditionLabel)
                    }
                }.font(.system(size:11))
                if let i=globalIndex {
                    if !model.globalOSC[i].isValid {Text("수신 주소를 확인하세요.").font(.caption).foregroundStyle(.orange)}
                } else if let issue=model.inputOSCIssue(key,sceneID:scene,textured:row.textured) {
                    Text(issue).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
    @ViewBuilder private var outputCell: some View {
        if let spec=row.spec {
            let route=currentRoute.output
            let issue=model.outputIssue(for:key,sceneID:scene,textured:row.textured)
            VStack(alignment:.leading,spacing:8) {
                HStack(spacing:10) {
                    Toggle("송신",isOn:output(\.enabled)).toggleStyle(.checkbox).accessibilityIdentifier("mapOutputEnabled_"+row.id)
                    if spec.supportsOutputMode {
                        Picker("출력 방식",selection:Binding(get:{route.behavior == .trigger ? ParameterOutputMode.trigger : .continuous},set:{mode in
                            update {$0.output.mode=mode;$0.output.configured=true}
                        })) {
                            Text("연속값").tag(ParameterOutputMode.continuous);Text("트리거").tag(ParameterOutputMode.trigger)
                        }.labelsHidden().pickerStyle(.segmented).frame(width:150).accessibilityIdentifier("mapOutputMode_"+row.id)
                    }
                    Spacer(minLength:0)
                    MappingSendStatus(model:model,row:row)
                }
                OSCMapAddressField(value:output(\.address),identifier:"mapOutputAddress_"+row.id)
                HStack(spacing:6) {
                    if route.sendsTriggerValue(spec:spec) {
                        Text(route.behavior == .trigger ? (spec.outputOnly ? (spec.eventOutput ? "교차마다 Float 1.0 · 1회" : "값 변경마다 Float 1.0 · 1회") : "입력마다 Float 1.0 · 1회") : "이벤트마다 Float 1.0 · 1회")
                            .font(.system(size:11)).foregroundStyle(.secondary)
                            .help(row.outputRangeLabel ?? "")
                    } else {
                        Text("Float").font(.system(size:11)).foregroundStyle(.secondary)
                        numberField("최소",value:output(\.minimum),id:"mapOutputMin_"+row.id)
                        Text("→").foregroundStyle(.secondary)
                        numberField("최대",value:output(\.maximum),id:"mapOutputMax_"+row.id)
                        if spec.eventOutput {Text("교차마다").font(.system(size:11)).foregroundStyle(.secondary)}
                    }
                    Spacer(minLength:0)
                    Button("송신 테스트") {model.testControlOutput(key)}
                        .controlSize(.small).disabled(!row.active || issue != nil)
                        .accessibilityIdentifier("mapOutputTest_"+row.id)
                        .help(row.active ? "이 출력만 한 번 보냅니다. 송신 체크 상태는 바뀌지 않습니다." : "이 씬을 재생할 때 송신 테스트를 사용할 수 있습니다.")
                }
                if let issue {Text(issue).font(.caption).foregroundStyle(.orange)}
            }
        } else {
            VStack(alignment:.leading,spacing:8) {
                Text("출력 없음").foregroundStyle(.secondary)
                Text("글로벌 동작은 OSC 입력으로 실행합니다.").font(.system(size:11)).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,minHeight:88,alignment:.leading)
        }
    }
    private func numberField(_ name: String,value: Binding<Double>,id: String) -> some View {
        TextField(name,value:value,format:.number.grouping(.never).precision(.fractionLength(1...6)))
            .font(.system(size:11,design:.monospaced)).frame(width:64)
            .accessibilityLabel("송신 "+name).accessibilityIdentifier(id)
    }
}

/// Commit address edits only on Enter/blur so sorted rows do not jump while typing.
private struct OSCMapAddressField: View {
    @Binding var value: String
    let identifier: String
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing:6) {
            TextField("/osc/address",text:$draft).font(.system(size:11,design:.monospaced))
                .focused($focused).accessibilityIdentifier(identifier).onSubmit {commit()}
                .help(draft)
            Button {
                commit();NSPasteboard.general.clearContents();NSPasteboard.general.setString(draft,forType:.string)
            } label: {Image(systemName:"doc.on.doc").font(.system(size:12))}
                .buttonStyle(.plain).foregroundStyle(.secondary).help("OSC 주소 복사")
                .accessibilityLabel("주소 복사").accessibilityIdentifier(identifier+"_copy")
        }.onAppear {draft=value}
            .onChange(of:value) {_,newValue in if !focused {draft=newValue}}
            .onChange(of:focused) {_,isFocused in if !isFocused {commit()}}
            .onDisappear {if focused {commit()}}
    }
    private func commit() {if draft != value {value=draft}}
}

private struct MappingReceiveStatus: View {
    let model: OrbitModel
    let row: MappingRow
    private var receipt: OSCReceipt? {
        if let id=row.globalID {return model.globalReceipts[id]}
        guard row.active,let spec=row.spec,!spec.outputOnly else {return nil}
        return model.latestOSCInput(for:[spec.id])
    }
    var body: some View {
        TimelineView(.periodic(from:.now,by:0.1)) {context in
            let received=receipt
            HStack(spacing:4) {
                OSCReceiveLight(receipt:model.oscRunning ? received : nil,date:context.date,title:row.title)
                Text(received.map {String(format:"수신 %.3f",$0.value)} ?? "수신 —").monospacedDigit()
            }.font(.system(size:11)).foregroundStyle(.secondary)
        }.accessibilityIdentifier("mappingActivity_"+row.id)
    }
}

private struct MappingSendStatus: View {
    let model: OrbitModel
    let row: MappingRow
    var body: some View {
        TimelineView(.periodic(from:.now,by:0.1)) {context in
            let delivery=row.spec.flatMap {spec in row.sceneID.flatMap {model.controlDelivery(for:spec.id,sceneID:$0,textured:row.textured)}}
            let age=delivery.map {context.date.timeIntervalSince($0.at)} ?? 2
            let recent=row.active && age>=0 && age<1
            let failed=delivery?.error != nil
            HStack(spacing:4) {
                Circle().fill(failed ? Color.orange : recent ? orbitAccent : Color.white.opacity(0.12))
                    .overlay(Circle().stroke(Color.white.opacity(recent ? 0.9 : 0),lineWidth:1)).frame(width:8,height:8)
                Text(failed ? "송신 실패" : delivery.map {String(format:"송신 %.3f",$0.value)} ?? "송신 —")
                    .monospacedDigit().lineLimit(1)
            }.font(.system(size:11)).foregroundStyle(failed ? Color.orange : .secondary)
                .help(delivery.map {($0.error ?? "이 Mac에서 전송 완료 · 상대 수신 확인 아님")+" · "+$0.at.formatted(date:.omitted,time:.standard)} ?? "아직 보낸 신호가 없습니다.")
        }.accessibilityIdentifier("mappingSendActivity_"+row.id)
    }
}

/// All local network interfaces are visible; never mistake loopback for a remote sender's target.
private struct OSCLocalAddressView: View {
    var body: some View {
        TimelineView(.periodic(from:.now,by:3)) { _ in
            let addresses=OSCNetworkAddress.current()
            VStack(alignment:.leading,spacing:3) {
                Text("이 Mac · 수신 IP").font(.caption).foregroundStyle(.secondary)
                if let first=addresses.first {
                    Menu {
                        ForEach(addresses) {item in
                            Button("\(item.interface) · \(item.address) 복사") {
                                NSPasteboard.general.clearContents();NSPasteboard.general.setString(item.address,forType:.string)
                            }
                        }
                        Text("송신 장치와 연결된 네트워크의 IP를 사용하세요.")
                    } label: {
                        Text(first.address+(addresses.count>1 ? " +\(addresses.count-1)" : "")).font(.system(size:12,design:.monospaced))
                            .foregroundStyle(.white)
                    }.menuStyle(.borderlessButton).accessibilityIdentifier("oscLocalIP")
                        .help(addresses.map {"\($0.interface): \($0.address)"}.joined(separator:"\n"))
                } else {
                    Text("네트워크 IP 없음").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("oscLocalIP")
                }
            }.frame(width:165,alignment:.leading)
        }
    }
}

/// Shared by the overall map and each parameter's input panel.
struct DirectOSCInputFields: View {
    @ObservedObject var model: OrbitModel
    let key: String
    let sceneID: String
    let textured: Bool
    private var route: ParameterRoute {model.route(for:key,sceneID:sceneID,textured:textured)}
    private var address: String {model.inputOSCAddress(key,sceneID:sceneID,textured:textured)}
    private var issue: String? {model.inputOSCIssue(key,sceneID:sceneID,textured:textured)}
    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                Toggle("OSC 수신",isOn:Binding(get:{route.input.receivesDirectOSC},set:{value in
                    model.setRoute(key,sceneID:sceneID,textured:textured) {$0.input.directOSCEnabled=value}
                })).accessibilityIdentifier("directOSCEnabled")
                Spacer()
                Button("기본 주소") {model.setRoute(key,sceneID:sceneID,textured:textured) {$0.input.directOSCAddress=nil;$0.input.directOSCArgument=nil}}
                    .disabled(route.input.directOSCAddress == nil && route.input.directOSCArgument == nil).accessibilityIdentifier("resetInputOSCAddress")
                Button("복사") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(address,forType:.string)}
                    .accessibilityIdentifier("copyInputOSCAddress")
            }
            TextField("수신 OSC 주소",text:Binding(get:{address},set:{value in
                model.setRoute(key,sceneID:sceneID,textured:textured) {$0.input.directOSCAddress=value}
            })).font(.system(size:11,design:.monospaced)).accessibilityIdentifier("directOSCAddress")
            if let issue {Text(issue).font(.caption).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)}
            else {
                Text(model.parameterSpec(key,sceneID:sceneID,textured:textured).isTrigger
                     ? "이 씬 재생 중 · \(route.input.oscArgument+1)번째 Float ≥ 0.5 수신마다 1회"
                     : "이 씬 재생 중 · \(route.input.oscArgument+1)번째 Float 0.0–1.0")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
}
