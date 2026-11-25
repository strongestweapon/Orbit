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

/// A single overview; editing an inactive scene never changes the on-air scene.
struct OSCMappingView: View {
    @ObservedObject var model: OrbitModel
    let close: () -> Void
    @State private var scope = 0
    @State private var signalType = 0
    @State private var sceneFilter = ""
    @State private var selectedID: String?
    @State private var editingParameter: MappingRow?
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
    private func loadNetworkSettings() {
        receivePort=model.port;outputHost=model.oscOutputDestination.host;outputPort=String(model.oscOutputDestination.port)
    }
    private func applyNetworkSettings() {
        if model.applyOSCNetworkSettings(receivePort:receivePort,output:proposedOutput) {loadNetworkSettings()}
    }

    private var rows: [MappingRow] {
        let query=search.trimmingCharacters(in:.whitespacesAndNewlines)
        return model.mappingRows.filter { row in
            (scope == 1 || signalType == 0 || (signalType == 1 ? !row.isEvent : row.isEvent))
            && (scope == 0 || (scope == 1 ? row.globalID != nil : row.sceneID == (sceneFilter.isEmpty ? model.selectedSceneID : sceneFilter)))
            && (sourceFilter == 0 || row.globalID != nil || row.textured == (sourceFilter == 2))
            && (query.isEmpty || [row.title,row.scope,row.address,row.searchText].joined(separator:" ").localizedCaseInsensitiveContains(query))
        }
    }
    private var selected: MappingRow? { rows.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("OSC 전체 맵").font(.title2)
                Text("입력 Float 0.0–1.0").foregroundStyle(.secondary)
                Spacer()
                Button("닫기",action:close).keyboardShortcut(.cancelAction)
            }
            HStack(alignment:.bottom,spacing:12) {
                OSCLocalAddressView()
                VStack(alignment:.leading,spacing:3) {
                    Text("OSC 수신 · UDP 포트").font(.caption).foregroundStyle(.secondary)
                    TextField("9000",text:$receivePort).frame(width:100).accessibilityIdentifier("oscReceivePort")
                }
                Divider().frame(height:32)
                VStack(alignment:.leading,spacing:3) {
                    Text("공통 OSC 출력 · 대상 IP / 호스트").font(.caption).foregroundStyle(.secondary)
                    TextField("127.0.0.1",text:$outputHost).frame(minWidth:150,maxWidth:230).accessibilityIdentifier("oscOutputHost")
                }
                VStack(alignment:.leading,spacing:3) {
                    Text("출력 UDP 포트").font(.caption).foregroundStyle(.secondary)
                    TextField("9001",text:$outputPort).frame(width:100).accessibilityIdentifier("oscOutputPort")
                }
                Button(networkChanged || model.oscRunning ? "적용" : "다시 연결",action:applyNetworkSettings).disabled((!networkChanged && model.oscRunning) || networkIssue != nil).accessibilityIdentifier("applyOSCNetwork")
                Spacer()
                Text("모든 씬의 OSC 출력에 적용\n127.0.0.1 = 이 Mac")
                    .font(.caption).foregroundStyle(.secondary)
            }.onSubmit {if networkIssue == nil && (networkChanged || !model.oscRunning) {applyNetworkSettings()}}
            if networkChanged,let issue=networkIssue {Text(issue).font(.caption).foregroundStyle(.orange)}
            if !model.oscRunning {Text(model.oscState).font(.caption).foregroundStyle(.orange)}
            Divider()
            HStack {
                Picker("범위",selection:$scope) { Text("전체").tag(0);Text("글로벌").tag(1);Text("영상별").tag(2) }
                    .pickerStyle(.segmented).frame(width:280).accessibilityIdentifier("mappingScope")
                if scope == 2 {
                    Picker("영상",selection:$sceneFilter) {
                        Text("현재 씬").tag("")
                        ForEach(model.scenes.filter { !$0.testScene }) { Text($0.name).tag($0.id) }
                    }
                }
                Spacer()
            }
            if scope != 1 {
            HStack {
                Picker("신호 종류",selection:$signalType) {Text("전체 신호").tag(0);Text("연속값").tag(1);Text("트리거 이벤트").tag(2)}
                    .pickerStyle(.segmented).frame(width:330).accessibilityIdentifier("mappingSignalType")
                Picker("영상 소스",selection:$sourceFilter) {Text("모든 방식").tag(0);Text("실시간 생성").tag(1);Text("원본 재생").tag(2)}
                    .frame(width:200).accessibilityIdentifier("mappingSource")
                Spacer()
            }
            }
            HStack {
                TextField("이벤트·파라미터·씬·OSC 주소 검색",text:$search).accessibilityIdentifier("mappingSearch")
                Text("\(rows.count)개").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("수신 주소 / 제어 출력").frame(width:300,alignment:.leading)
                Text("제어 대상 / 씬").frame(maxWidth:.infinity,alignment:.leading)
                Text("값 범위 / 트리거 조건").frame(width:250,alignment:.leading)
                Text("최근 값 · 상태").frame(width:85,alignment:.trailing)
            }.padding(.horizontal,9).font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
            ScrollView {
            LazyVStack(spacing:3) {
                ForEach(rows) { row in
                    Button {
                        selectedID=row.id
                        if row.globalID == nil {editingParameter=row}
                    } label: {
                        HStack(spacing:12) {
                            VStack(alignment:.leading,spacing:4) {
                                Text(row.address).font(.system(size:11,design:.monospaced)).fixedSize(horizontal:false,vertical:true)
                                if row.globalID == nil {
                                    Text(connectionLabel(row)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                }
                            }.frame(width:300,alignment:.leading)
                            VStack(alignment:.leading,spacing:4) {
                                Text(row.title)
                                if row.globalID == nil {Text(row.scope).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                            }.frame(maxWidth:.infinity,alignment:.leading)
                            VStack(alignment:.leading,spacing:3) {
                                if row.globalID == nil {Text(row.inputRangeLabel).foregroundStyle(.secondary)}
                                Text(row.conditionLabel).foregroundStyle(.primary)
                                if let output=row.outputRangeLabel {Text(output).foregroundStyle(.secondary)}
                            }.font(.system(size:11)).monospacedDigit()
                                .fixedSize(horizontal:false,vertical:true).frame(width:250,alignment:.leading)
                                .accessibilityElement(children:.combine).accessibilityIdentifier("mappingValues_"+row.id)
                            VStack(alignment:.trailing,spacing:4) {
                                MappingLiveStatus(model:model,row:row)
                                if row.globalID == nil || !row.active {Text(row.active ? "현재 씬" : "비활성").font(.caption).foregroundStyle(.secondary)}
                            }.frame(width:85,alignment:.trailing)
                        }.padding(.horizontal,9).padding(.vertical,row.globalID == nil ? 8 : 6)
                            .frame(minHeight:row.globalID == nil ? 66 : 30)
                            .background(selectedID == row.id ? orbitAccent.opacity(0.12) : Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:6))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).id(row.id).accessibilityIdentifier("mapping_"+row.id)
                }
                if rows.isEmpty {Text("조건에 맞는 항목이 없습니다. 검색이나 필터를 변경하세요.").foregroundStyle(.secondary).padding()}
            }
            }.accessibilityIdentifier("mappingList")
                .onChange(of:scope) {_,_ in if let first=rows.first {proxy.scrollTo(first.id,anchor:.top)}}
                .onChange(of:signalType) {_,_ in if let first=rows.first {proxy.scrollTo(first.id,anchor:.top)}}
                .onChange(of:sceneFilter) {_,_ in if let first=rows.first {proxy.scrollTo(first.id,anchor:.top)}}
            }.frame(maxHeight:.infinity)
            Divider()
            if let id=selected?.globalID,let index=model.globalOSC.firstIndex(where:{$0.id==id}) {
                globalEditor(index:index)
            } else {Text("항목을 누르면 해당 동작의 OSC 주소와 입출력을 설정합니다.").foregroundStyle(.secondary)}
        }.padding(20).frame(width:min(1120,(NSScreen.main?.visibleFrame.width ?? 1200)-60),height:min(880,(NSScreen.main?.visibleFrame.height ?? 960)-60)).background(Color(white:0.07)).font(.system(size:12))
            .tint(orbitAccent).accentColor(orbitAccent)
            .buttonStyle(OrbitSecondaryButtonStyle())
            .textFieldStyle(.roundedBorder)
            .onAppear {loadNetworkSettings()}
            .onChange(of:scope) {_,_ in if selected == nil {selectedID=nil}}
            .onChange(of:signalType) {_,_ in selectedID=nil}
            .onChange(of:sourceFilter) {_,_ in selectedID=nil}
            .onChange(of:search) {_,_ in selectedID=nil}
            .onChange(of:sceneFilter) {_,_ in selectedID=nil}
            .sheet(item:$editingParameter) { row in
                if let spec=row.spec,let sceneID=row.sceneID {
                    ParameterRoutingPopover(model:model,key:spec.id,title:spec.title,initialTab:spec.outputOnly ? 1 : 0,
                        sceneID:sceneID,textured:row.textured) {editingParameter=nil}
                }
            }
    }

    private func globalEditor(index: Int) -> some View {
        let route=model.globalOSC[index]
        let target=route.action == .scene ? (model.scenes.first {$0.id==route.sceneID}?.name ?? "연결된 씬 없음") : route.action.label
        return VStack(alignment:.leading,spacing:10) {
            HStack {
                Text(target).fontWeight(.medium)
                Text("· 글로벌 트리거").foregroundStyle(.secondary)
                Spacer()
                Toggle("OSC 수신",isOn:$model.globalOSC[index].enabled).accessibilityIdentifier("globalOSCEnabled")
                Text("실행 \(model.globalReceipts[route.id]?.triggerCount ?? 0)회").monospacedDigit()
                Button("복사") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(route.address,forType:.string)}
                    .accessibilityIdentifier("copyGlobalOSCAddress")
            }
            TextField("수신 OSC 주소",text:$model.globalOSC[index].address).font(.system(size:11,design:.monospaced)).accessibilityIdentifier("globalOSCAddress")
            Text("\(route.argument+1)번째 OSC Float 0.0–1.0 · \(selected?.conditionLabel ?? "≥ 0.5 수신마다 1회")")
                .font(.caption).foregroundStyle(.secondary)
            if !route.isValid {Text("/로 시작하는 OSC 주소를 공백 없이 입력하세요.").foregroundStyle(.orange)}
        }
    }

    private func connectionLabel(_ row: MappingRow) -> String {
        guard let route=row.route else {return "→ 글로벌 이벤트"}
        let input=row.spec?.outputOnly == true ? "출력 전용 · 자동 발생" : (route.input.receivesDirectOSC ? "직접 수신 켜짐" : "직접 수신 꺼짐")+(route.input.enabled ? " · 영상 값으로 자동 실행" : "")
        if route.output.transport == .osc {return input+"\n출력: "+route.output.address+(route.output.enabled ? "" : " (꺼짐)")}
        return input+" · "+route.output.endpointLabel+(route.output.enabled ? "" : " (출력 꺼짐)")
    }

}

/// Read the latest packet on each tick, including packets whose value did not change.
private struct MappingLiveStatus: View {
    let model: OrbitModel
    let row: MappingRow
    private var receipt: OSCReceipt? {
        if let id=row.globalID {return model.globalReceipts[id]}
        guard row.active,let spec=row.spec,!spec.outputOnly else {return nil}
        return model.latestOSCInput(for:[spec.id])
    }
    var body: some View {
        TimelineView(.periodic(from:.now,by:0.05)) { context in
            let received=receipt
            HStack(spacing:4) {
                if row.spec?.outputOnly != true {
                    OSCReceiveLight(receipt:model.oscRunning ? received : nil,date:context.date,title:row.title)
                }
                if let spec=row.spec,spec.isTrigger,row.active {
                    Text("\(model.parameterEventCount(spec.id))회").monospacedDigit()
                } else {
                    let live=row.spec?.outputOnly == true && row.active ? row.spec.map {model.controlValue($0.id)} : received?.value
                    Text(live.map {String(format:"%.2f",$0)} ?? "—").monospacedDigit()
                }
            }
        }.accessibilityIdentifier("mappingActivity_"+row.id)
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
