import SwiftUI

private struct MappingRow: Identifiable {
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
}

/// A single paged overview; editing an inactive scene never changes the on-air scene.
struct OSCMappingView: View {
    @ObservedObject var model: OrbitModel
    let close: () -> Void
    @State private var scope = 0
    @State private var signalType = 0
    @State private var sceneFilter = ""
    @State private var page = 0
    @State private var selectedID: String?
    @State private var editingParameter: ParameterSpec?
    private let pageSize = 5

    private var rows: [MappingRow] {
        var result = model.globalOSC.map { route in
            MappingRow(id:route.id.uuidString,
                title:route.action == .scene ? (model.scenes.first { $0.id == route.sceneID }?.name ?? "씬 선택") : route.action.label,
                scope:route.triggerMode == .threshold ? "글로벌 · 임계값 통과" : "글로벌 · 수신마다 트리거",address:route.address,active:route.enabled,
                value:model.globalReceipts[route.id]?.value,globalID:route.id)
        }
        for scene in model.scenes where !scene.testScene {
            for textured in [false,true] {
                let routes = (textured ? model.settings[scene.id]?.textureParameterRoutes : model.settings[scene.id]?.parameterRoutes) ?? [:]
                for (key,route) in routes.sorted(by: { $0.key < $1.key }) {
                    guard route.input.behavior != .continuous || route.input.sensorID != nil || route.input.enabled || route.output.isListed(defaultRoute:ParameterRoute.defaults(scene:scene.id,parameter:key).output) else { continue }
                    let spec = model.specs(for:scene.id,textured:textured).first {$0.id==key} ?? ParameterSpec.find(key)
                    let sensor = model.sensors.first { $0.id == route.input.sensorID }
                    result.append(MappingRow(id:"\(scene.id):\(textured):\(key)",title:spec.title,
                        scope:scene.name+(textured ? " · 원본" : "")+" · "+(spec.isTrigger || spec.eventOutput ? "트리거 이벤트" : "연속값"),address:spec.outputOnly ? (spec.eventOutput ? "교차 이벤트 → 출력" : "시뮬레이션 → 출력") : (route.input.sourceParameter.map {source in "영상 값 · "+(model.specs(for:scene.id,textured:textured).first {$0.id==source}?.title ?? source)} ?? sensor?.address ?? "버튼 / 입력 연결 없음"),
                        active:model.selectedSceneID == scene.id && model.usesTexture == textured,
                        value:spec.outputOnly && model.selectedSceneID == scene.id ? model.controlValue(key) : sensor?.value,sceneID:scene.id,textured:textured,spec:spec,route:route))
                }
            }
        }
        return result.filter { row in
            let event = row.globalID != nil || row.spec?.isTrigger == true || row.spec?.eventOutput == true
            return (signalType == 0 || (signalType == 1 ? !event : event)) && (scope == 0 || (scope == 1 ? row.globalID != nil : row.sceneID == (sceneFilter.isEmpty ? model.selectedSceneID : sceneFilter)))
        }
    }
    private var selected: MappingRow? { rows.first { $0.id == selectedID } }
    private var visible: [MappingRow] { Array(rows.dropFirst(page*pageSize).prefix(pageSize)) }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("OSC 매핑").font(.title2)
                Text("Float 0.0–1.0 · UDP \(model.port)").foregroundStyle(.secondary)
                Spacer()
                Button(model.oscRunning ? "수신 중지" : "수신 시작") { model.oscRunning ? model.stopOSC() : model.startOSC() }
                Button("닫기",action:close).keyboardShortcut(.cancelAction)
            }
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
                Button("글로벌 추가") {
                    let route = GlobalOSCMapping(address:"/orbit/cue/\(model.globalOSC.count+1)",action:.restart)
                    model.globalOSC.append(route);scope=1;selectedID=route.id.uuidString;page=max(0,(model.globalOSC.count-1)/pageSize)
                }.accessibilityIdentifier("addGlobalOSC")
            }
            Picker("신호 종류",selection:$signalType) {Text("전체 신호").tag(0);Text("연속값").tag(1);Text("트리거 이벤트").tag(2)}
                .pickerStyle(.segmented).accessibilityIdentifier("mappingSignalType")
            HStack {
                Text("수신 주소 / 제어 출력").frame(width:280,alignment:.leading)
                Text("제어 대상 / 범위").frame(maxWidth:.infinity,alignment:.leading)
                Text("최근 값 · 상태").frame(width:125,alignment:.trailing)
            }.font(.caption).foregroundStyle(.secondary)
            VStack(spacing:4) {
                ForEach(visible) { row in
                    Button { selectedID=row.id } label: {
                        HStack(spacing:12) {
                            VStack(alignment:.leading,spacing:4) {
                                Text(row.address).font(.system(size:11,design:.monospaced)).lineLimit(1).truncationMode(.middle)
                                Text(row.route?.output.enabled == true ? "→ "+(row.route?.output.endpointLabel ?? "") : (row.globalID == nil ? "출력 꺼짐" : "이벤트 동작"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(width:280,alignment:.leading)
                            VStack(alignment:.leading,spacing:4) {
                                Text(row.title);Text(row.scope).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth:.infinity,alignment:.leading)
                            VStack(alignment:.trailing,spacing:4) {
                                TimelineView(.periodic(from:.now,by:0.2)) { _ in
                                    let live = row.spec?.outputOnly == true && row.active ? row.spec.map {model.controlValue($0.id)} : row.value
                                    if let spec=row.spec, spec.isTrigger, row.active {
                                        Text("\(model.parameterEventCount(spec.id))회").monospacedDigit()
                                    } else {Text(live.map {String(format:"%.2f",$0)} ?? "—").monospacedDigit()}
                                }
                                Text(row.active ? (row.globalID == nil ? "현재 씬" : "항상 활성") : "비활성").font(.caption).foregroundStyle(.secondary)
                            }.frame(width:125,alignment:.trailing)
                        }.padding(9).frame(height:53)
                            .background(selectedID == row.id ? orbitAccent.opacity(0.12) : Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:6))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("mapping_"+row.id)
                }
                if visible.isEmpty { Text("등록된 매핑이 없습니다. 파라미터 옆 연결 버튼에서 추가하세요.").foregroundStyle(.secondary).padding() }
                Spacer(minLength:0)
            }.frame(height:281,alignment:.top)
            HStack {
                Text("\(rows.count)개 매핑 · 현재 \(model.selectedScene?.name ?? "")").foregroundStyle(.secondary)
                Spacer()
                Button("이전") { page-=1 }.disabled(page==0)
                Text("\(page+1) / \(max(1,(rows.count+pageSize-1)/pageSize))").monospacedDigit()
                Button("다음") { page+=1 }.disabled((page+1)*pageSize>=rows.count)
            }
            Divider()
            if let row = selected {
                if let id = row.globalID, let index = model.globalOSC.firstIndex(where: { $0.id == id }) {
                    globalEditor(index:index)
                } else { parameterEditor(row) }
            } else { Text("매핑을 선택하면 아래에서 설정을 편집합니다.").foregroundStyle(.secondary) }
            Spacer(minLength:0)
        }.padding(20).frame(width:820,height:710).background(Color(white:0.07)).font(.system(size:12))
            .tint(orbitAccent).accentColor(orbitAccent)
            .buttonStyle(OrbitSecondaryButtonStyle())
            .textFieldStyle(.roundedBorder)
            .onChange(of:scope) { _,_ in
                if let index=rows.firstIndex(where: { $0.id == selectedID }) { page=index/pageSize }
                else { page=0;selectedID=nil }
            }
            .onChange(of:signalType) {_,_ in page=0;selectedID=nil}
            .onChange(of:sceneFilter) { _,_ in page=0;selectedID=nil }
            .onChange(of:rows.count) { _,count in page=min(page,max(0,(count-1)/pageSize)) }
            .sheet(item:$editingParameter) { spec in
                ParameterRoutingPopover(model:model,key:spec.id,title:spec.title) { editingParameter=nil }
            }
    }

    private func globalEditor(index: Int) -> some View {
        let route = model.globalOSC[index]
        return VStack(alignment:.leading,spacing:10) {
            HStack {
                Toggle("활성",isOn:$model.globalOSC[index].enabled)
                Picker("트리거 방식",selection:Binding(get:{route.triggerMode ?? .event},set:{model.globalOSC[index].triggerMode=$0})) {
                    Text("수신마다 ≥ 0.5").tag(ParameterInputMode.event)
                    Text("임계값 통과").tag(ParameterInputMode.threshold)
                }.frame(width:230)
                if route.triggerMode == .threshold {
                    TextField("임계값",value:Binding(get:{route.threshold?.level ?? 0.5},set:{value in
                        var t=route.threshold ?? .init();t.level=value;model.globalOSC[index].threshold=t.sanitized
                    }),format:.number).frame(width:60)
                }
                Spacer()
                Button("삭제",role:.destructive) { model.globalOSC.removeAll { $0.id == route.id };selectedID=nil }
            }
            HStack {
                TextField("/orbit/cue",text:$model.globalOSC[index].address).accessibilityIdentifier("globalOSCAddress")
                Stepper("인수 \(route.argument)",value:$model.globalOSC[index].argument,in:0...15).frame(width:120)
            }
            HStack {
                Picker("동작",selection:$model.globalOSC[index].action) {
                    ForEach(GlobalOSCAction.allCases) { Text($0.label).tag($0) }
                }.frame(width:240)
                if route.action == .scene {
                    Picker("씬",selection:Binding(get:{route.sceneID ?? ""},set:{model.globalOSC[index].sceneID=$0})) {
                        Text("선택").tag("");ForEach(model.scenes) { Text($0.name).tag($0.id) }
                    }
                }
                Spacer()
                Text("실행 \(model.globalReceipts[route.id]?.triggerCount ?? 0)회").monospacedDigit()
            }
            if !route.isValid { Text("/로 시작하는 OSC 주소를 공백 없이 입력하세요.").foregroundStyle(.orange) }
        }
    }

    private func parameterEditor(_ row: MappingRow) -> some View {
        VStack(alignment:.leading,spacing:10) {
            Text("\(row.scope) · \(row.title)").fontWeight(.medium)
            if let route = row.route, let spec = row.spec, let sceneID = row.sceneID {
                if spec.outputOnly {
                    Text(spec.detail).font(.caption).foregroundStyle(.secondary)
                    if sceneID == model.selectedSceneID {
                        Button("출력 상세") { editingParameter=spec }
                    }
                } else if spec.isTrigger {
                    Text("독립 트리거 · "+spec.detail).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Toggle("입력 활성",isOn:inputBinding(row,\.enabled,fallback:false))
                        Spacer()
                        if row.active {Button("이벤트 실행") {model.triggerParameter(spec.id)};Button("이벤트 입출력 설정") {editingParameter=spec}}
                    }
                } else {
                HStack {
                    Toggle("입력 활성",isOn:inputBinding(row,\.enabled,fallback:false))
                    Picker("센서",selection:inputBinding(row,\.sensorID,fallback:nil)) {
                        Text("선택 안 함").tag(Optional<UUID>.none)
                        ForEach(model.sensors) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                HStack {
                    Text("연속값 · 최소·최대")
                    TextField("최소",value:normalizedInputBinding(row,\.minimum),format:.number.precision(.fractionLength(0...3))).frame(width:75)
                    Text("…")
                    TextField("최대",value:normalizedInputBinding(row,\.maximum),format:.number.precision(.fractionLength(0...3))).frame(width:75)
                    if route.input.behavior == .continuous {
                        Text("전환 초")
                        TextField("초",value:inputBinding(row,\.smoothingSeconds,fallback:8),format:.number).frame(width:45)
                    }
                    Spacer()
                    if sceneID == model.selectedSceneID && row.textured == model.usesTexture {
                        Button("입력·출력 상세") { editingParameter=spec }
                    }
                }
                }
                Text("출력: "+(route.output.enabled ? route.output.endpointLabel : "꺼짐")).foregroundStyle(.secondary)
                if !row.active { Text("이 씬의 설정만 편집합니다. 현재 재생 중인 영상은 유지됩니다.").foregroundStyle(.secondary) }
            }
        }
    }
    private func normalizedInputBinding(_ row: MappingRow, _ path: WritableKeyPath<ParameterInputRoute,Double>) -> Binding<Double> {
        let spec = row.spec ?? ParameterSpec.find("")
        let raw = inputBinding(row,path,fallback:path == \.minimum ? spec.range.lowerBound : spec.range.upperBound)
        return Binding(get:{spec.normalized(raw.wrappedValue)},set:{raw.wrappedValue=spec.rawValue(normalized:$0)})
    }
    private func inputBinding<T>(_ row: MappingRow, _ path: WritableKeyPath<ParameterInputRoute,T>, fallback: T) -> Binding<T> {
        Binding(get: {
            guard let scene=row.sceneID,let key=row.spec?.id else { return fallback }
            return (row.textured ? model.settings[scene]?.textureParameterRoutes : model.settings[scene]?.parameterRoutes)?[key]?.input[keyPath:path] ?? fallback
        },set: { value in
            guard let scene=row.sceneID,let spec=row.spec,var settings=model.settings[scene] else { return }
            var routes = (row.textured ? settings.textureParameterRoutes : settings.parameterRoutes) ?? [:]
            var route=routes[spec.id] ?? ParameterRoute.defaults(scene:scene,parameter:spec.id,spec:spec)
            route.input[keyPath:path]=value
            if spec.isTrigger {
                route.input.mode = route.input.sourceParameter != nil || route.input.behavior == .threshold ? .threshold : .event
                route.input.minimum=0;route.output.mode = .event
            } else {route.input.mode=nil;route.input.sourceParameter=nil;route.output.mode=nil}
            route.input.minimum=spec.clamp(route.input.minimum);route.input.maximum=spec.clamp(route.input.maximum)
            route.input.smoothingSeconds=route.input.smoothingSeconds.isFinite ? min(30,max(0,route.input.smoothingSeconds)) : 0
            routes[spec.id]=route
            if row.textured { settings.textureParameterRoutes=routes } else { settings.parameterRoutes=routes }
            model.settings[scene]=settings
        })
    }
}
