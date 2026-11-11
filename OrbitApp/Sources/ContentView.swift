import SwiftUI

private let orbitAccent = Color(red:0.64,green:0.92,blue:0.64)
private let orbitPanel = Color(white:0.085)
private let orbitBrandImage = Bundle.main.url(forResource:"OrbitLogo",withExtension:"png")
    .flatMap { NSImage(contentsOf:$0) }
private enum OrbitPanel: String, Identifiable {
    case look, sensors, output
    var id: String { rawValue }
    var title: String {
        switch self { case .look:return "공통 조절";case .sensors:return "센서 입력";case .output:return "출력 설정" }
    }
}

struct ContentView: View {
    @ObservedObject var model: OrbitModel
    @State private var panel: OrbitPanel?
    @State private var initialSensorID: UUID?
    var body: some View {
        VStack(spacing:0) {
            transport
            Divider()
            sceneRibbon
            VStack(spacing:10) {
                HStack(spacing:12) {
                    Text(model.selectedScene?.name ?? "Orbit").font(.system(size:19,weight:.medium))
                    Spacer()
                    if model.selectedScene?.texture != nil {
                        Picker("영상 소스",selection:Binding(get:{model.renderStyle},set:{model.setRenderStyle($0)})) {
                            Text("실시간 생성").tag(0);Text("원본 재생").tag(1)
                        }.pickerStyle(.segmented).frame(width:225).accessibilityIdentifier("renderStyle")
                    }
                    if model.selectedScene?.testScene == false {
                        Toggle("원본 비교",isOn:$model.showReference).toggleStyle(.button).controlSize(.small)
                    }
                }.frame(height:30)
                preview.frame(maxWidth:.infinity,maxHeight:.infinity)
                HStack(spacing:14) {
                    VStack(alignment:.leading,spacing:5) {
                        caption("펼친 영상",trailing:"15444 × 300")
                        OrbitMetalView(model:model,mode:0).frame(height:48)
                            .overlay(Rectangle().stroke(model.outputActive ? .red : Color.white.opacity(0.12),lineWidth:model.outputActive ? 2 : 1))
                    }
                    VStack(alignment:.leading,spacing:5) {
                        caption("출력 · 16:9",trailing:model.outputSizeLabel)
                        OrbitMetalView(model:model,mode:2).frame(width:100,height:56.25)
                    }.frame(width:150)
                }.frame(height:72)
            }.padding(.horizontal,18).padding(.bottom,12)
            Divider()
            sceneControls
            Divider()
            ConnectionStrip(model:model) { sensorID in
                initialSensorID=sensorID;panel = .sensors
            }
            footer
        }
        .background(Color(white:0.045)).tint(orbitAccent)
        .sheet(item:$panel) { selected in
            OrbitSettingsPanel(model:model,panel:selected,initialSensorID:$initialSensorID) { panel=nil }
        }
        .alert("Orbit",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0 {model.errorMessage=nil}})) {
            Button("확인",role:.cancel){model.errorMessage=nil}
        } message:{Text(model.errorMessage ?? "")}
    }
    private var transport: some View {
        HStack(spacing:14) {
            HStack(spacing:7) {
                if let image = orbitBrandImage {
                    Image(nsImage:image).renderingMode(.original).resizable().interpolation(.high).scaledToFit()
                        .frame(width:38,height:38).accessibilityHidden(true)
                }
                Text("ORBIT").font(.custom("AvenirNext-Medium",fixedSize:17)).tracking(4)
            }.accessibilityElement(children:.combine).accessibilityLabel("Orbit")
            Divider().frame(height:24)
            Button { model.playing.toggle() } label:{
                Label(model.playing ? "일시정지" : "재생",systemImage:model.playing ? "pause.fill" : "play.fill").frame(width:85)
            }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("playbackToggle")
                .modifier(AcceptFirstClick())
                .help("재생 / 일시정지 · Space")
            Button {model.restartPlayback()} label:{Image(systemName:"backward.end.fill")}.help("처음부터")
            Text(model.playing ? "PLAYING" : "PAUSED").font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
            Text(model.playbackTimeLabel).font(.system(size:11,design:.monospaced)).monospacedDigit()
                .frame(width:76,alignment:.leading).accessibilityIdentifier("playbackTime")
            Spacer()
            Circle().fill(model.outputActive ? .red : .gray).frame(width:7,height:7)
            Text(model.outputStatus).font(.system(size:10)).lineLimit(1)
            Button {panel = .output} label:{Label("출력 설정",systemImage:"display")}.accessibilityIdentifier("openOutput")
            if model.outputOpen {
                Button {model.toggleOutputFullscreen()} label:{Image(systemName:model.outputFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")}
                    .help(model.outputFullscreen ? "출력 창 모드" : "출력 전체화면").accessibilityIdentifier("toggleOutputFullscreen")
            }
            Button(model.outputOpen ? "출력 중지" : "출력 시작") {
                if model.outputOpen {model.stopOutput()}
                else {model.startOutput()}
            }.buttonStyle(.borderedProminent).tint(model.outputActive ? .red : orbitAccent)
        }.padding(.horizontal,18).frame(height:58)
    }
    private var sceneRibbon: some View {
        HStack(spacing:6) {
            ForEach(Array(model.scenes.enumerated()),id:\.element.id) { i,scene in
                Button {
                    if model.selectedSceneID != scene.id {model.selectedSceneID=scene.id}
                } label:{
                    HStack(spacing:7) {
                        Text(String(format:"%02d",i+1)).font(.system(size:9,design:.monospaced)).foregroundStyle(model.selectedSceneID==scene.id ? orbitAccent : .secondary)
                        Text(scene.name.replacingOccurrences(of:" ",with:"\n")).font(.system(size:11,weight:.medium)).multilineTextAlignment(.leading).lineLimit(2)
                        Spacer(minLength:0)
                    }.padding(.horizontal,9).frame(maxWidth:.infinity).frame(height:47)
                        .background(model.selectedSceneID==scene.id ? Color.white.opacity(0.11) : orbitPanel,in:RoundedRectangle(cornerRadius:7))
                        .overlay(RoundedRectangle(cornerRadius:7).stroke(model.selectedSceneID==scene.id ? orbitAccent.opacity(0.65) : .clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).modifier(AcceptFirstClick()).accessibilityIdentifier("scene_"+scene.id)
                    .accessibilityAddTraits(model.selectedSceneID==scene.id ? .isSelected : [])
                    .help(scene.description)
            }
        }.padding(.horizontal,18).padding(.vertical,10)
    }
    private var preview: some View {
        HStack(spacing:10) {
            if model.showReference,let scene=model.selectedScene,!scene.testScene {
                VStack(spacing:6) {
                    caption(scene.referenceImage==nil ? "참조 영상" : "참조 스틸컷")
                    if let name=scene.referenceImage,let url=Bundle.main.url(forResource:name,withExtension:"png"),let image=NSImage(contentsOf:url) {
                        Color.black.overlay {Image(nsImage:image).resizable().scaledToFit()}.clipped()
                    } else {ReferenceVideoView(playback:model.comparison)}
                }.frame(maxWidth:.infinity)
            }
            VStack(spacing:6) {
                if model.showReference {caption(model.usesTexture ? "원본 재생" : "코드 생성")}
                OrbitMetalView(model:model,mode:1)
                    .clipShape(RoundedRectangle(cornerRadius:9))
                    .overlay(RoundedRectangle(cornerRadius:9).stroke(model.outputActive ? .red : Color.white.opacity(0.12),lineWidth:model.outputActive ? 3 : 1))
            }.frame(maxWidth:.infinity)
        }
    }
    private var sceneControls: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:10) {
                Text(model.selectedScene?.testScene == true ? "LED TEST" : (model.usesTexture ? "원본 재생 조절" : "\(model.selectedScene?.name ?? "") · 파라미터 \(model.shaderParameters.count)개"))
                    .font(.system(size:11,weight:.semibold)).accessibilityIdentifier("sceneParameterCount")
                Spacer()
                Button {panel = .look} label:{Label(model.usesTexture ? "원본 조절" : "공통 조절",systemImage:"slider.horizontal.3")}
                    .disabled(model.selectedScene?.testScene == true).accessibilityIdentifier("openLook")
            }.frame(height:22)
            if model.selectedScene?.testScene == true {
                HStack(spacing:24) {
                    PatternPicker(model:model).frame(width:225)
                    MappedParameterSlider(model:model,key:"brightness",title:"밝기").frame(width:200)
                    Spacer()
                }
            } else if model.usesTexture {
                HStack(spacing:24) {
                    MappedParameterSlider(model:model,key:"speed",title:"재생 속도",range:0...3,suffix:"×")
                    MappedParameterSlider(model:model,key:"brightness",title:"밝기")
                    MappedParameterSlider(model:model,key:"energy",title:"발광")
                }
            } else {
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:24),count:min(4,max(1,model.shaderParameters.count))),spacing:12) {
                    ForEach(model.shaderParameters) { control in
                        MappedParameterSlider(model:model,key:control.id,title:control.title,
                                              range:control.minimum...control.maximum,suffix:control.unit)
                    }
                }.id(model.selectedSceneID)
            }
        }.padding(.horizontal,20).padding(.vertical,12).background(orbitPanel)
    }
    private var footer: some View {
        HStack {
            Text(model.usesTexture ? "추출 원본 재생" : "실시간 코드 생성 · 이미지/영상 텍스처 없음")
            Spacer()
            Text(model.controlOutputEnabled ? model.controlOutputStatus : model.lastMessage).lineLimit(1)
            Text("v"+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? ""))
            Text("Metal · \(Int(model.fps.rounded())) fps").frame(width:105,alignment:.trailing).monospacedDigit()
        }.font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary).padding(.horizontal,20).frame(height:23).background(orbitPanel)
    }
    private func binding(_ key:String)->Binding<Double> {
        Binding(get:{Double(model.value(key))},set:{model.setValue(key,Float($0))})
    }
    private func caption(_ text:String,trailing:String="")->some View {
        HStack {Text(text);Spacer();Text(trailing)}.font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
    }
}

private struct OrbitSettingsPanel: View {
    @ObservedObject var model:OrbitModel
    let panel:OrbitPanel
    @Binding var initialSensorID: UUID?
    let close:()->Void
    @State private var tab=0
    @State private var selectedSensor:UUID?
    @State private var sensorPage=0
    var body:some View {
        VStack(spacing:0) {
            HStack {Text(panel.title).font(.system(size:19,weight:.semibold));Spacer();Text(model.selectedScene?.name ?? "").foregroundStyle(.secondary);Button {close()} label:{Image(systemName:"xmark")}.keyboardShortcut(.cancelAction)}
                .padding(20)
            Divider()
            Group {
                switch panel {case .look:look;case .sensors:sensors;case .output:output}
            }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            Divider()
            HStack {
                if panel == .look {Button("연출 기본값 복원"){model.resetSceneAppearance()}}
                Spacer();Button("닫기",action:close).keyboardShortcut(.defaultAction)
            }.padding(16)
        }.frame(width:640,height:520).background(Color(white:0.07)).tint(orbitAccent)
            .onAppear {
                selectedSensor=initialSensorID ?? model.sensors.first?.id
                sensorPage=(model.sensors.firstIndex {$0.id==selectedSensor} ?? 0)/6
            }
    }
    private var look:some View {
        Group {
            if model.usesTexture { referenceLook } else { shaderLook }
        }
    }
    private var shaderLook:some View {
        VStack(alignment:.leading,spacing:15) {
            Picker("공통 조절",selection:$tab) {
                Text("재생 · 색").tag(0);Text("빛 · 소멸").tag(1)
                if !model.connectedCompatibilityParameters.isEmpty {Text("기존 연결").tag(2)}
            }.pickerStyle(.segmented)
            if tab == 0 {
                parameter("전체 재생 속도","speed",range:0...3)
                parameter("전체 밝기","brightness")
                parameter("색상 이동","hueShift",range:-0.5...0.5)
                Text("모든 씬에 공통인 재생·색 조절입니다. 씬 고유의 파라미터는 메인 화면에 모두 표시됩니다.")
                    .font(.system(size:11)).foregroundStyle(.secondary)
            } else if tab == 1 {
                parameter("빛이 남는 범위","coverage")
                parameter("소멸 경계 부드러움","gapSoftness")
                parameter("빈 구간 이동","gapMotion")
                parameter("조각화","fragmentation")
                Text("링의 점등 범위와 빈 구간을 제어합니다. 범위 0은 전체 소등, 1은 전체 범위입니다.")
                    .font(.system(size:10)).foregroundStyle(.secondary)
            } else {
                ForEach(model.connectedCompatibilityParameters) { control in
                    parameter(control.title,control.id,range:control.minimum...control.maximum)
                }
                Text("이전 버전에서 연결한 입력·출력을 유지합니다. 연결 버튼에서 확인하거나 해제할 수 있습니다.")
                    .font(.system(size:11)).foregroundStyle(.secondary)
            }
        }
    }
    private var referenceLook:some View {
        VStack(alignment:.leading,spacing:15) {
            Picker("연출 설정",selection:$tab) {Text("밀도 · 색").tag(0);Text("움직임").tag(1);Text("빛 · 소멸").tag(2)}.pickerStyle(.segmented)
            if tab==0 {
                parameter(model.usesTexture ? "질감 대비" : "밀도","density")
                parameter(model.usesTexture ? "발광" : "에너지","energy")
                parameter("색상 이동","hueShift",range:-0.5...0.5)
                Text(model.usesTexture ? "추출한 원본을 재생합니다." : "빛의 형태·색·질감·시간 변화를 셰이더 코드로 생성합니다.").font(.system(size:10)).foregroundStyle(.secondary)
            } else if tab==1 {
                MappedParameterSlider(model:model,key:"speed",title:"전체 속도",range:0...3,suffix:"×")
                parameter(model.usesTexture ? "부분 흐름 변형" : "움직임","turbulence")
                if model.usesTexture && model.selectedScene?.texture?.kind=="image" {parameter("전체 회전","rotation")}
                Text(model.usesTexture ? "원본 재생 1.00×는 추출 구간의 원래 속도입니다." : "속도는 시간 진행을, 움직임은 씬 내부의 변화를 조절합니다.").font(.system(size:10)).foregroundStyle(.secondary)
            } else {
                parameter("빛이 남는 범위","coverage")
                parameter("소멸 경계 부드러움","gapSoftness")
                parameter("빈 구간 이동","gapMotion")
                parameter("조각화","fragmentation")
                Text("범위 0은 전체 소등, 1은 전체 범위입니다.").font(.system(size:10)).foregroundStyle(.secondary)
            }
        }
    }
    private var sensors:some View {
        VStack(alignment:.leading,spacing:15) {
            HStack {
                Text("OSC · UDP").font(.system(size:11,weight:.semibold))
                TextField("포트",text:$model.port).frame(width:70).disabled(model.oscRunning)
                Button(model.oscRunning ? "수신 중지" : "수신 시작"){if model.oscRunning {model.stopOSC()} else {model.startOSC()}}
                Spacer();Button {model.addSensor();selectedSensor=model.sensors.last?.id;sensorPage=max(0,(model.sensors.count-1)/6)} label:{Label("입력 추가",systemImage:"plus")}
            }
            HStack(alignment:.top,spacing:22) {
                VStack(spacing:5) {
                    ForEach(Array(model.sensors.dropFirst(sensorPage*6).prefix(6))) {sensor in
                        Button {selectedSensor=sensor.id} label:{
                            HStack {SensorDot(sensor:sensor,running:model.oscRunning);Text(sensor.name).lineLimit(1);Spacer()}.padding(9).frame(height:35)
                                .background(selectedSensor==sensor.id ? Color.white.opacity(0.11) : .clear,in:RoundedRectangle(cornerRadius:5))
                        }.buttonStyle(.plain)
                    }
                    Spacer(minLength:0)
                    HStack {
                        Button {sensorPage=max(0,sensorPage-1)} label:{Image(systemName:"chevron.left")}.disabled(sensorPage==0)
                        Text("\(sensorPage+1) / \(max(1,(model.sensors.count+5)/6))").font(.system(size:10)).monospacedDigit()
                        Button {sensorPage+=1} label:{Image(systemName:"chevron.right")}.disabled((sensorPage+1)*6>=model.sensors.count)
                    }
                }.frame(width:180,height:275)
                Divider().frame(height:275)
                if let sensor=sensorBinding {
                    VStack(alignment:.leading,spacing:12) {
                        labeled("이름") {TextField("센서 이름",text:sensor.name)}
                        labeled("OSC 주소") {TextField("/park/sensor",text:sensor.address).font(.system(size:11,design:.monospaced))}
                        HStack {labeled("입력 최소") {TextField("0",value:sensor.minimum,format:.number)};labeled("입력 최대") {TextField("100",value:sensor.maximum,format:.number)}}
                        Stepper("OSC 인수 \(sensor.wrappedValue.argument)",value:sensor.argument,in:0...15)
                        HStack {Text("마지막 수신 값").foregroundStyle(.secondary);Spacer();Text(sensor.wrappedValue.value.map{String(format:"%.2f",$0)} ?? "대기 중").monospacedDigit()}
                        Button("입력 삭제",role:.destructive) {
                            let id=sensor.wrappedValue.id;model.sensors.removeAll{$0.id==id};selectedSensor=model.sensors.first?.id;sensorPage=min(sensorPage,max(0,(model.sensors.count-1)/6))
                        }
                    }.frame(maxWidth:.infinity)
                } else {Text("입력을 추가하세요.").foregroundStyle(.secondary).frame(maxWidth:.infinity)}
            }
            Text("장치에서 이 Mac의 IP와 UDP 포트로 전송 · 바인딩 0.0.0.0").font(.system(size:10)).foregroundStyle(.secondary)
        }.font(.system(size:11)).textFieldStyle(.roundedBorder)
    }
    private var sensorBinding:Binding<SensorInput>? {
        guard let id=selectedSensor,model.sensors.contains(where:{$0.id==id}) else{return nil}
        return Binding(get:{model.sensors.first{$0.id==id}!},set:{value in if let i=model.sensors.firstIndex(where:{$0.id==id}) {model.sensors[i]=value}})
    }
    private var output:some View {
        VStack(alignment:.leading,spacing:12) {
            Picker("출력 설정",selection:$tab){Text("디스플레이 · 크기").tag(0);Text("링 방향 · 테스트").tag(1)}.pickerStyle(.segmented)
            if tab==0 {
                Picker("출력 모니터",selection:$model.selectedDisplayID) {
                    Text("현재 화면 (자동)").tag(UInt32(0))
                    ForEach(model.displays){Text("\($0.name) · \($0.pixels)").tag($0.id)}
                }.accessibilityIdentifier("outputDisplay")
                Picker("영상 해상도",selection:$model.outputResolution) {
                    ForEach(OutputResolution.allCases){Text($0.label).tag($0)}
                }.accessibilityIdentifier("outputResolution")
                if model.outputResolution == .custom {
                    HStack {
                        Text("가로")
                        TextField("1920",value:$model.customOutputWidth,format:.number.grouping(.never))
                            .frame(width:90).textFieldStyle(.roundedBorder)
                            .onSubmit {model.normalizeOutputWidth()}.accessibilityIdentifier("customOutputWidth")
                        Text("× \(model.customOutputHeight) · 16:9").monospacedDigit()
                        Spacer()
                        Text("320–7680 px · 16 px 단위").font(.system(size:10)).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(model.outputStatus).lineLimit(1);Spacer()
                    Button(model.outputFullscreen ? "창 모드" : "전체화면"){model.toggleOutputFullscreen()}
                        .disabled(!model.outputOpen).accessibilityIdentifier("outputSettingsFullscreen")
                    Button(model.outputOpen ? "출력 중지" : "출력 시작") {
                        if model.outputOpen {model.stopOutput()} else {model.startOutput()}
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("outputSettingsStartStop")
                }
                Divider()
                Text(model.outputSizeLabel).font(.system(size:24,weight:.medium,design:.monospaced))
                Text("출력은 별도 창으로 열립니다. 전체화면은 그 창이 있는 모니터에 맞춰 확대합니다. 자동 해상도는 창 크기와 화면에 맞춰 바뀝니다.")
                    .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Text("항상 16:9 유지 · 남는 영역은 검정\nLED 원본 배치: 3840 × 2160 (1:1 픽셀 확인은 4K 선택)")
                    .font(.system(size:10)).foregroundStyle(.secondary)
            } else {
                parameter("링 시작점","angleOffset")
                HStack {
                    Toggle("진행 방향 반전",isOn:boolBinding("flipU"))
                        .disabled(model.route(for:"flipU").input.enabled && model.selectedScene?.testScene == false)
                    ParameterRouteButton(model:model,key:"flipU",title:"진행 방향 반전")
                }
                HStack {
                    Toggle("안쪽 / 바깥쪽 반전",isOn:boolBinding("flipV"))
                        .disabled(model.route(for:"flipV").input.enabled && model.selectedScene?.testScene == false)
                    ParameterRouteButton(model:model,key:"flipV",title:"안쪽 / 바깥쪽 반전")
                }
                Divider()
                Button("LED 테스트 씬 열기") {model.selectedSceneID="06_calibration";close()}
                Text("구간 번호·그리드·안팎 방향·RGB·회색·단일 픽셀 패턴을 사용할 수 있습니다.").font(.system(size:11)).foregroundStyle(.secondary)
            }
        }.font(.system(size:12))
    }
    private func parameter(_ title:String,_ key:String,range:ClosedRange<Double>=0...1)->some View {
        MappedParameterSlider(model:model,key:key,title:title,range:range,suffix:model.parameterSpec(key).unit)
    }
    private func boolBinding(_ key:String)->Binding<Bool> {Binding(get:{model.value(key)>0.5},set:{model.setValue(key,$0 ? 1:0)})}
    private func labeled<V:View>(_ title:String,@ViewBuilder content:()->V)->some View {
        VStack(alignment:.leading,spacing:5){Text(title).font(.system(size:10)).foregroundStyle(.secondary);content()}
    }
}

struct SensorDot:View {
    let sensor:SensorInput
    let running:Bool
    var body:some View {
        TimelineView(.periodic(from:.now,by:1)){context in
            let state=sensor.receptionState(running:running,now:context.date)
            Circle().fill(state == .receiving ? orbitAccent : (state == .stale ? .orange : .gray)).frame(width:6,height:6)
        }
    }
}
private struct PatternPicker:View {
    @ObservedObject var model:OrbitModel
    let names=["구간 번호 / 방향","픽셀 그리드","안쪽 / 바깥쪽","RGB","16단계 회색","화이트","블랙","이동 마커","구간 이음새","1픽셀 체크"]
    var body:some View {
        Picker("테스트",selection:Binding(get:{Int(model.value("testPattern"))},set:{model.setValue("testPattern",Float($0))})) {
            ForEach(names.indices,id:\.self){Text(names[$0]).tag($0)}
        }
    }
}
private struct AcceptFirstClick:ViewModifier {
    @ViewBuilder func body(content:Content)->some View {
        if #available(macOS 15.0,*) {content.allowsWindowActivationEvents(true)} else {content}
    }
}
