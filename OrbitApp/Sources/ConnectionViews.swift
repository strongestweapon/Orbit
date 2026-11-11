import SwiftUI

/// Two paged lists keep every connection reachable without scrolling the operator screen.
struct ConnectionStrip: View {
    @ObservedObject var model: OrbitModel
    let openSensor: (UUID?) -> Void
    @State private var inputPage = 0
    @State private var outputPage = 0
    @State private var editingOutput: ParameterSpec?
    private let pageSize = 2
    private var outputs: [ParameterSpec] { model.outputParameterSpecs }

    var body: some View {
        VStack(spacing:8) {
            HStack(spacing:12) {
                Button {openSensor(nil)} label: {
                    listHeading("입력 센서",count:model.sensors.count,subtitle:"OSC · UDP \(model.port)",icon:"arrow.down.left")
                }.buttonStyle(.plain).accessibilityIdentifier("openSensors")
                HStack(spacing:8) {
                    ForEach(Array(model.sensors.dropFirst(inputPage*pageSize).prefix(pageSize))) { sensor in
                        SensorConnectionCard(model:model,sensor:sensor) {openSensor(sensor.id)}
                    }
                    if model.sensors.isEmpty {empty("등록된 입력이 없습니다. ‘입력 관리’에서 추가하세요.")}
                }.frame(maxWidth:.infinity)
                pager(page:$inputPage,count:model.sensors.count,prefix:"input")
                HStack(spacing:8) {
                    Button("입력 관리") {openSensor(nil)}.accessibilityIdentifier("manageInputs")
                    Button(model.oscRunning ? "수신 중지" : "수신 시작") {
                        if model.oscRunning {model.stopOSC()} else {model.startOSC()}
                    }.accessibilityIdentifier("connectionReceiveToggle")
                }.frame(width:162,alignment:.trailing)
            }
            HStack(spacing:12) {
                listHeading("제어 출력",count:outputs.count,subtitle:"현재 씬 · \(model.usesTexture ? "원본 재생" : "실시간 생성")",icon:"arrow.up.right")
                HStack(spacing:8) {
                    ForEach(Array(outputs.dropFirst(outputPage*pageSize).prefix(pageSize))) { spec in
                        OutputConnectionCard(model:model,spec:spec) {editingOutput=spec}
                    }
                    if outputs.isEmpty {
                        empty(model.selectedScene?.testScene == true ? "LED 테스트 중에는 제어 신호를 보내지 않습니다." : "연결된 출력이 없습니다. 영상 파라미터를 Live / OSC에 연결하세요.")
                    }
                }.frame(maxWidth:.infinity)
                pager(page:$outputPage,count:outputs.count,prefix:"control")
                HStack(spacing:8) {
                    Menu {
                        ForEach(model.parameterSpecs) {spec in
                            Button(spec.title) {
                                model.setRoute(spec.id) {$0.output.configured=true}
                                outputPage=(outputs.firstIndex {$0.id==spec.id} ?? 0)/pageSize
                                editingOutput=spec
                            }
                        }
                    } label:{Text("출력 추가")}
                        .menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("addControlOutput")
                        .disabled(model.selectedScene?.testScene != false)
                    Toggle("송신",isOn:$model.controlOutputEnabled)
                        .toggleStyle(.switch).controlSize(.mini).fixedSize().accessibilityIdentifier("controlOutputToggle")
                        .disabled(model.selectedScene?.testScene != false)
                        .help("현재 씬에서 활성화한 모든 제어 출력의 자동 송신")
                }.frame(width:162,alignment:.trailing)
            }
        }.font(.system(size:10)).controlSize(.small).padding(.horizontal,20).padding(.vertical,10)
            .sheet(item:$editingOutput) { spec in
                ParameterRoutingPopover(model:model,key:spec.id,title:spec.title,initialTab:1) {editingOutput=nil}
                    .id(model.controlEmissionID(spec.id))
            }
            .onChange(of:model.selectedSceneID) {_,_ in outputPage=0;editingOutput=nil}
            .onChange(of:model.renderStyle) {_,_ in outputPage=0;editingOutput=nil}
            .onChange(of:outputs.count) {_,count in outputPage=min(outputPage,max(0,(count-1)/pageSize))}
            .onChange(of:model.sensors.count) {_,count in inputPage=min(inputPage,max(0,(count-1)/pageSize))}
    }

    private func listHeading(_ title:String,count:Int,subtitle:String,icon:String) -> some View {
        VStack(alignment:.leading,spacing:4) {
            HStack(spacing:5) {
                Image(systemName:icon).foregroundStyle(.secondary)
                Text(title).fontWeight(.semibold)
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
            Text(subtitle).font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(width:137,alignment:.leading)
    }
    private func pager(page:Binding<Int>,count:Int,prefix:String) -> some View {
        HStack(spacing:3) {
            if count > pageSize {
                Button {page.wrappedValue-=1} label:{Image(systemName:"chevron.left")}
                    .disabled(page.wrappedValue==0).accessibilityIdentifier(prefix+"PreviousPage")
                Text("\(page.wrappedValue+1)/\((count+pageSize-1)/pageSize)").font(.system(size:9)).monospacedDigit()
                Button {page.wrappedValue+=1} label:{Image(systemName:"chevron.right")}
                    .disabled((page.wrappedValue+1)*pageSize>=count).accessibilityIdentifier(prefix+"NextPage")
            }
        }.buttonStyle(.plain)
    }
    private func empty(_ title:String) -> some View {
        Text(title).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
    }
}

private struct SensorConnectionCard: View {
    @ObservedObject var model: OrbitModel
    let sensor: SensorInput
    let action: () -> Void
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) { context in
            let state=sensor.receptionState(running:model.oscRunning,now:context.date)
            Button(action:action) {
                VStack(alignment:.leading,spacing:4) {
                    HStack(spacing:5) {
                        SensorDot(sensor:sensor,running:model.oscRunning)
                        Text(sensor.name).fontWeight(.medium).lineLimit(1)
                        Spacer(minLength:2)
                        Text(valueLabel(state)).monospacedDigit().foregroundStyle(state == .receiving ? .green : .secondary).lineLimit(1)
                    }
                    HStack(spacing:5) {
                        Text(sensor.address).font(.system(size:9,design:.monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength:2)
                        Text(state.rawValue).foregroundStyle(state == .stale ? .orange : .secondary).lineLimit(1)
                    }.font(.system(size:9)).foregroundStyle(.secondary)
                }.padding(.horizontal,10).frame(maxWidth:.infinity).frame(height:44)
                    .background(Color.white.opacity(0.045),in:RoundedRectangle(cornerRadius:6)).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("inputSensor_"+sensor.id.uuidString)
                .help("\(sensor.name) · \(sensor.address) · 입력 설정 열기")
        }
    }
    private func valueLabel(_ state:SensorReceptionState) -> String {
        guard let value=sensor.value else {return "—"}
        return (state == .receiving ? "" : "마지막 ")+String(format:"%.1f",value)
    }
}

private struct OutputConnectionCard: View {
    @ObservedObject var model: OrbitModel
    let spec: ParameterSpec
    let action: () -> Void
    private var route:ParameterOutputRoute {model.route(for:spec.id).output}
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) {context in
            let state=status(now:context.date)
            Button(action:action) {
                VStack(alignment:.leading,spacing:4) {
                    HStack(spacing:5) {
                        Circle().fill(state.1).frame(width:6,height:6)
                        Text("\(spec.title) → \(route.displayName)").fontWeight(.medium).lineLimit(1)
                        Spacer(minLength:2)
                        Text(valueLabel).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing:5) {
                        Text(route.endpointLabel).font(.system(size:9,design:.monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength:2)
                        Text(state.0).foregroundStyle(state.1).lineLimit(1)
                    }.font(.system(size:9)).foregroundStyle(.secondary)
                }.padding(.horizontal,10).frame(maxWidth:.infinity).frame(height:44)
                    .background(Color.white.opacity(0.045),in:RoundedRectangle(cornerRadius:6)).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("controlOutput_"+spec.id)
                .help("\(spec.title) → \(route.displayName)\n\(route.endpointLabel)\n송신 표시는 이 Mac에서 보낸 상태이며 상대 장치의 수신 확인은 아닙니다.")
        }
    }
    private var valueLabel:String {
        if let delivery=model.controlDelivery(for:spec.id), delivery.error == nil {
            return "송신 "+format(delivery.value)
        }
        let value=model.parameterValues[spec.id] ?? model.baseParameterValue(spec.id)
        return route.mappedValue(value,spec:spec).map {"예정 "+format($0)} ?? "—"
    }
    private func format(_ value:Double) -> String {String(format:route.transport == .midi ? "%.0f" : "%.2f",value)}
    private func status(now:Date) -> (String,Color) {
        if model.outputIssue(for:spec.id) != nil {return ("설정 확인",.orange)}
        let delivery=model.controlDelivery(for:spec.id)
        if let delivery, delivery.error != nil {return ("송신 실패",.orange)}
        if !model.controlOutputEnabled {return (delivery == nil ? "송신 꺼짐" : "마지막 송신",.secondary)}
        if !route.enabled {return ("비활성",.secondary)}
        guard let delivery else {return ("송신 대기",.secondary)}
        return now.timeIntervalSince(delivery.at)<5 ? ("송신 중",.cyan) : ("송신 지연",.orange)
    }
}
