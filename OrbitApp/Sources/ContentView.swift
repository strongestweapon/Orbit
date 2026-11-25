import SwiftUI

// Blue marks filled controls and selection; text on dark surfaces stays readable.
let orbitAccent = Color(.sRGB,red:0,green:0,blue:1,opacity:1)

struct OrbitSecondaryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.bordered)
            .tint(configuration.role == .destructive ? .red : .white)
    }
}

private let orbitPanel = Color(white:0.085)
private let orbitBrandImage = Bundle.main.url(forResource:"OrbitLogo",withExtension:"png")
    .flatMap { NSImage(contentsOf:$0) }
private enum OrbitPanel: String, Identifiable {
    case look, output, performance, oscMappings
    var id: String { rawValue }
    var title: String {
        switch self { case .look:return "공통 조절";case .output:return "출력 설정";case .performance:return "FPS · 성능";case .oscMappings:return "OSC 매핑" }
    }
}

private enum SceneControlSection: Int, CaseIterable, Identifiable {
    case basic = 0, rhythm = 3, orbit = 4, interaction = 5, color = 2, output = 6
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .basic:return "기본 움직임"
        case .rhythm:return "리듬"
        case .orbit:return "궤도"
        case .interaction:return "상호작용"
        case .color:return "색상"
        case .output:return "출력 신호"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: OrbitModel
    @State private var panel: OrbitPanel?
    @State private var controlSection: SceneControlSection = .basic
    private var groupedControls: Bool { model.shaderParameters.contains { $0.group >= 2 } }
    private var mainParameters: [ShaderParameter] { model.shaderParameters.filter { $0.group < 2 } }
    private var sectionParameters: [ShaderParameter] {
        controlSection == .basic ? mainParameters : model.shaderParameters.filter { $0.group == controlSection.rawValue }
    }
    var body: some View {
        VStack(spacing:0) {
            transport
            Divider()
            sceneRibbon
            VStack(spacing:10) {
                HStack(spacing:12) {
                    Text(model.selectedScene?.name ?? "Orbit").font(.system(size:19,weight:.medium))
                    Spacer()
                    FrameRateReadout(telemetry:model.telemetry,isOutput:false,enabled:model.previewsEnabled)
                    FrameRateReadout(telemetry:model.telemetry,isOutput:true,enabled:model.outputOpen)
                    Button { panel = .performance } label: { Image(systemName:"speedometer") }
                        .help("FPS 제한 / 최대 성능 측정").accessibilityLabel("FPS 성능 설정").accessibilityIdentifier("openPerformance")
                    if model.selectedScene?.texture != nil {
                        Picker("영상 소스",selection:Binding(get:{model.renderStyle},set:{model.setRenderStyle($0)})) {
                            Text("실시간 생성").tag(0);Text("원본 재생").tag(1)
                        }.pickerStyle(.segmented).frame(width:225).accessibilityIdentifier("renderStyle")
                    }
                    if model.selectedScene?.hasReference == true {
                        Toggle("원본 비교",isOn:$model.showReference).toggleStyle(.button).controlSize(.small)
                            .tint(model.showReference ? orbitAccent : .white)
                    }
                }.frame(height:30)
                if model.previewsEnabled {
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
                } else {
                    VStack(spacing:12) {
                        Image(systemName:"eye.slash").font(.system(size:26))
                        Text("프리뷰 꺼짐 · GPU 사용 절약")
                        Text(model.outputOpen ? "LED 출력은 계속됩니다" : "프리뷰 설정에서 다시 켤 수 있습니다").font(.caption).foregroundStyle(.secondary)
                        Button("프리뷰 켜기") { model.previewPolicy = .always }
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                        .overlay(RoundedRectangle(cornerRadius:9).stroke(model.outputActive ? .red : Color.white.opacity(0.12),lineWidth:model.outputActive ? 3 : 1))
                }
            }.padding(.horizontal,18).padding(.bottom,12)
            Divider()
            sceneControls
            Divider()
            footer
        }
        .onChange(of:model.selectedSceneID) { _ in controlSection = .basic }
        .onChange(of:model.usesTexture) { _ in controlSection = .basic }
        .background(Color(white:0.045)).tint(orbitAccent).accentColor(orbitAccent)
        .buttonStyle(OrbitSecondaryButtonStyle())
        .sheet(item:$panel) { selected in
            if selected == .performance {
                PerformanceView(model:model,measurement:model.performance) { panel=nil }

            } else if selected == .oscMappings {
                OSCMappingView(model:model) { panel=nil }
            } else {
                OrbitSettingsPanel(model:model,panel:selected) { panel=nil }
            }
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
            PlaybackTimeReadout(telemetry:model.telemetry)
            Spacer()
            Button {panel = .oscMappings} label:{Label("OSC 매핑",systemImage:"point.3.connected.trianglepath.dotted")}
                .accessibilityIdentifier("openOSCMapping")
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
                        Text(String(format:"%02d",i+1)).font(.system(size:9,design:.monospaced)).foregroundStyle(model.selectedSceneID==scene.id ? Color.white : .secondary)
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
            if model.showReference,let scene=model.selectedScene,scene.hasReference {
                VStack(spacing:6) {
                    caption(scene.referenceImage==nil ? "참조 영상" : "참조 스틸컷")
                    if let name=scene.referenceImage,let url=Bundle.main.url(forResource:name,withExtension:"png"),let image=NSImage(contentsOf:url) {
                        Color.black.overlay {Image(nsImage:image).resizable().scaledToFit()}.clipped()
                    } else {ReferenceVideoView(playback:model.comparison)}
                }.frame(maxWidth:.infinity)
            }
            VStack(spacing:6) {
                if model.showReference && model.selectedScene?.hasReference == true {caption(model.usesTexture ? "원본 재생" : "코드 생성")}
                OrbitMetalView(model:model,mode:1)
                    .clipShape(RoundedRectangle(cornerRadius:9))
                    .overlay(RoundedRectangle(cornerRadius:9).stroke(model.outputActive ? .red : Color.white.opacity(0.12),lineWidth:model.outputActive ? 3 : 1))
            }.frame(maxWidth:.infinity)
        }
    }
    private var sceneControls: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:10) {
                Text(model.selectedScene?.testScene == true ? "LED TEST" : (model.usesTexture ? "원본 재생 조절" : "\(model.selectedScene?.name ?? "") · 연속값 \(model.shaderParameters.count)개"))
                    .font(.system(size:11,weight:.semibold)).accessibilityIdentifier("sceneParameterCount")
                Spacer()
                if model.selectedScene?.testScene == false {
                    Button {model.resetSceneAppearance()} label:{Label("초기값 복원",systemImage:"arrow.counterclockwise")}
                        .accessibilityIdentifier("resetSceneAppearance")
                        .accessibilityLabel("\(model.selectedScene?.name ?? "") 초기값 복원")
                        .help("현재 씬의 조절값과 재생 속도를 초기값으로 복원합니다. OSC 매핑과 링 방향은 유지됩니다.")
                }
                Button {panel = .look} label:{Label(model.usesTexture ? "원본 조절" : "공통 조절",systemImage:"slider.horizontal.3")}
                    .disabled(model.selectedScene?.testScene == true).accessibilityIdentifier("openLook")
            }.frame(height:22)
            if model.selectedScene?.testScene == true {
                HStack(spacing:24) {
                    PatternPicker(model:model).frame(width:285)
                    MappedParameterSlider(model:model,key:"brightness",title:"밝기").frame(width:200)
                    if [2,10,11].contains(Int(model.value("testPattern"))) {
                        VStack(alignment:.leading,spacing:4) {
                            Text("1–5 구간별 고유색 · 안쪽 빨강 띠 · 바깥쪽 파랑 띠")
                            Text(model.value("flipV") > 0.5 ? "안팎 반전 켜짐 · 색과 표식 위치가 뒤집힙니다" : "도면 기준: 각 줄 위 = 바깥쪽 파랑 · 아래 = 안쪽 빨강")
                                .foregroundStyle(.secondary)
                        }.font(.system(size:11)).accessibilityIdentifier("radialTestLegend")
                    }
                    Spacer()
                }
            } else if model.usesTexture {
                HStack(spacing:24) {
                    MappedParameterSlider(model:model,key:"speed",title:"재생 속도")
                    MappedParameterSlider(model:model,key:"brightness",title:"밝기")
                    MappedParameterSlider(model:model,key:"energy",title:"발광")
                }
            } else if groupedControls {
                groupedParameterControls
            } else {
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:24),count:min(4,max(1,mainParameters.count))),spacing:12) {
                    ForEach(mainParameters) { control in
                        MappedParameterSlider(model:model,key:control.id,title:control.title)
                    }
                }.id(model.selectedSceneID)
            }
            if model.selectedScene?.testScene == false {
                Divider()
                SceneTriggerButtons(model:model)
            }
        }.padding(.horizontal,20).padding(.vertical,12).background(orbitPanel)
    }
    // Section navigation stays visible; the shared pane keeps the preview and
    // trigger buttons stationary while using full-size labels and sliders.
    private var groupedParameterControls: some View {
        VStack(spacing:12) {
            HStack(spacing:6) {
                ForEach(SceneControlSection.allCases) { section in
                    TimelineView(.periodic(from:.now,by:0.05)) { context in
                        let keys=(section == .basic ? mainParameters : model.shaderParameters.filter {$0.group == section.rawValue}).map(\.id)
                        let receipt=model.latestOSCInput(for:keys)
                        Button { controlSection=section } label: {
                            HStack(spacing:6) {
                                Text(section.title).font(.system(size:13,weight:.medium))
                                if section != .output {
                                    OSCReceiveLight(receipt:receipt,date:context.date,title:section.title)
                                        .accessibilityHidden(true)
                                }
                            }.frame(maxWidth:.infinity).frame(height:30)
                                .foregroundStyle(controlSection == section ? Color.white : Color.white.opacity(0.8))
                                .background(controlSection == section ? orbitAccent : Color.white.opacity(0.045),in:RoundedRectangle(cornerRadius:6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).modifier(AcceptFirstClick())
                            .accessibilityLabel(section.title)
                            .accessibilityValue((receipt?.activityLevel(at:context.date) ?? 0) > 0 ? "OSC 수신 중" : "")
                            .accessibilityIdentifier("sceneSection_\(section.rawValue)")
                            .accessibilityAddTraits(controlSection == section ? .isSelected : [])
                    }
                }
            }
            Group {
                if controlSection == .output {
                    HStack(spacing:12) {
                        ForEach(model.parameterSpecs.filter(\.outputOnly)) { signal in
                            VStack(alignment:.leading,spacing:7) {
                                HStack(spacing:5) {
                                    Text(signal.title).font(.system(size:13,weight:.medium)).help(signal.detail)
                                    ParameterRouteButton(model:model,key:signal.id,title:signal.title)
                                    Spacer(minLength:0)
                                }
                                TimelineView(.periodic(from:.now,by:0.1)) { _ in
                                    Text(String(format:"%.3f",model.controlValue(signal.id)))
                                        .font(.system(size:20,design:.monospaced)).monospacedDigit()
                                }.accessibilityIdentifier("signalValue_"+signal.id)
                                Text(model.route(for:signal.id).output.sendsTriggerValue(spec:signal)
                                     ? (signal.eventOutput ? "트리거 · 교차마다 1회" : "트리거 · 값 변경마다 1회")
                                     : (signal.eventOutput ? "연속값 · 교차마다" : "연속값 · 0.0–1.0"))
                                    .font(.system(size:12)).foregroundStyle(.secondary)
                            }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
                                .background(Color.white.opacity(0.025),in:RoundedRectangle(cornerRadius:6))
                        }
                    }
                } else {
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:24),count:min(4,max(1,sectionParameters.count))),spacing:14) {
                        ForEach(sectionParameters) { control in sceneParameterControl(control) }
                    }
                }
            }.id("\(model.selectedSceneID):\(controlSection.rawValue)")
                .frame(height:106,alignment:.top)
                .accessibilityElement(children:.contain).accessibilityLabel(controlSection.title)
        }
    }
    @ViewBuilder
    private func sceneParameterControl(_ control: ShaderParameter) -> some View {
        if control.group == 2 {
            VStack(alignment:.leading,spacing:6) {
                HStack(spacing:5) {
                    Circle().fill(model.value(control.id) >= 0.5 ? Color.white : Color(.sRGB,red:1,green:0,blue:0,opacity:1))
                        .frame(width:10,height:10).accessibilityHidden(true)
                    Text(control.title).font(.system(size:13)).help(control.detail)
                    ParameterRouteButton(model:model,key:control.id,title:control.title)
                }
                Picker(control.title,selection:Binding(
                    get:{model.value(control.id) >= 0.5 ? 1 : 0},
                    set:{model.setNormalizedParameterValue(control.id,Double($0))})) {
                        Text("레드").tag(0);Text("화이트").tag(1)
                    }.labelsHidden().pickerStyle(.segmented).controlSize(.regular)
                        .disabled(model.route(for:control.id).input.enabled)
                        .accessibilityIdentifier("parameter_"+control.id)
            }.frame(height:46)
        } else if control.isSwitch == true {
            VStack(alignment:.leading,spacing:6) {
                HStack(spacing:5) {
                    Text(control.title).font(.system(size:13)).help(control.detail)
                    ParameterRouteButton(model:model,key:control.id,title:control.title)
                    Spacer(minLength:0)
                }
                HStack {
                    Text(model.value(control.id) >= 0.5 ? "켜짐" : "꺼짐")
                        .font(.system(size:13)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle(control.title,isOn:Binding(
                        get:{model.value(control.id) >= 0.5},
                        set:{model.setNormalizedParameterValue(control.id,$0 ? 1:0)}))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(model.route(for:control.id).input.enabled)
                        .accessibilityIdentifier("parameter_"+control.id)
                }
            }.frame(height:46)
        } else {
            MappedParameterSlider(model:model,key:control.id,title:control.title,fontSize:13,controlHeight:46)
        }
    }
    private var footer: some View {
        HStack(spacing:12) {
            videoOutputStatus
            Divider().frame(height:12)
            OSCStatusStrip(model:model)
                .frame(maxWidth:.infinity,alignment:.leading)
            Text("v"+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? ""))
            OrbitUpdateMenu()
            Text("Metal · "+model.frameRate.label).frame(width:105,alignment:.trailing)
        }.font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary).padding(.horizontal,20).frame(height:32).background(orbitPanel)
    }
    private var videoOutputStatus: some View {
        let state = model.outputActive ? "영상 출력 중" : model.outputOpen ? "출력 프레임 대기" : "영상 출력 꺼짐"
        let mode = model.outputFullscreen ? "전체화면" : "창 모드"
        return HStack(spacing:5) {
            Circle().fill(model.outputActive ? .red : model.outputOpen ? .orange : .gray).frame(width:6,height:6)
            Text(state).foregroundStyle(.white).fixedSize()
            if model.outputOpen {
                Text(model.outputName).lineLimit(1).truncationMode(.middle).frame(maxWidth:150)
                Text("· "+mode).fixedSize()
            }
        }.font(.system(size:10,design:.monospaced))
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(state+(model.outputOpen ? " · \(model.outputName) · \(mode)" : ""))
            .accessibilityIdentifier("videoOutputStatus")
            .help(model.outputOpen ? "\(model.outputStatus) · \(mode) · \(model.outputSizeLabel)" : "영상 출력이 꺼져 있습니다.")
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
    let close:()->Void
    @State private var tab=0
    var body:some View {
        VStack(spacing:0) {
            HStack {Text(panel.title).font(.system(size:19,weight:.semibold));Spacer();Text(model.selectedScene?.name ?? "").foregroundStyle(.secondary)}
                .padding(20)
            Divider()
            Group {
                switch panel {case .look:look;case .output:output;case .performance,.oscMappings:EmptyView()}
            }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            Divider()
            HStack {
                Spacer();Button("닫기",action:close).keyboardShortcut(.cancelAction)
            }.padding(16)
        }.frame(width:640,height:520).background(Color(white:0.07)).tint(orbitAccent).accentColor(orbitAccent)
            .buttonStyle(OrbitSecondaryButtonStyle())
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
                parameter("전체 재생 속도","speed")
                parameter("전체 밝기","brightness")
                if model.parameterSpecs.contains(where: { $0.id == "hueShift" }) { parameter("색상 이동","hueShift") }
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
                    parameter(control.title,control.id)
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
                parameter("색상 이동","hueShift")
                Text(model.usesTexture ? "추출한 원본을 재생합니다." : "빛의 형태·색·질감·시간 변화를 셰이더 코드로 생성합니다.").font(.system(size:10)).foregroundStyle(.secondary)
            } else if tab==1 {
                parameter(model.usesTexture ? "부분 흐름 변형" : "움직임","turbulence")
                if model.usesTexture && model.selectedScene?.texture?.kind=="image" {parameter("전체 회전","rotation")}
                Text("부분 흐름과 회전을 조절합니다. 재생 속도·발광은 메인 화면에서 조절합니다.").font(.system(size:10)).foregroundStyle(.secondary)
            } else {
                parameter("빛이 남는 범위","coverage")
                parameter("소멸 경계 부드러움","gapSoftness")
                parameter("빈 구간 이동","gapMotion")
                parameter("조각화","fragmentation")
                Text("범위 0은 전체 소등, 1은 전체 범위입니다.").font(.system(size:10)).foregroundStyle(.secondary)
            }
        }
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
                Divider()
                Picker("운영 화면 프리뷰",selection:$model.previewPolicy) {
                    ForEach(PreviewPolicy.allCases) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("previewPolicy")
                Toggle("앱 실행 시 이전 영상 출력 상태 복원",isOn:$model.resumeOnLaunch)
                    .accessibilityIdentifier("resumeInstallation")
                if model.displayFallback { Text("저장한 모니터 없음 · 현재 화면으로 대체").foregroundStyle(.orange) }
                Text(model.outputSizeLabel).font(.system(size:20,weight:.medium,design:.monospaced))
                Text("출력은 별도 창으로 열립니다. 전체화면은 그 창이 있는 모니터에 맞춰 확대합니다. 자동 해상도는 창 크기와 화면에 맞춰 바뀝니다.")
                    .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Text("LED 5행 배치 고정 · 16:9 유지 · 남는 영역은 검정\n기준 3840 × 2160 · 링 프리뷰는 운영 화면 전용")
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
                Text("메인 화면의 Calibration 씬에서 구간 번호·그리드·안팎 방향·RGB·회색·단일 픽셀 패턴을 선택합니다.").font(.system(size:11)).foregroundStyle(.secondary)
            }
        }.font(.system(size:12))
    }
    private func parameter(_ title:String,_ key:String)->some View {
        MappedParameterSlider(model:model,key:key,title:title)
    }
    private func boolBinding(_ key:String)->Binding<Bool> {Binding(get:{model.value(key)>0.5},set:{model.setValue(key,$0 ? 1:0)})}
    private func labeled<V:View>(_ title:String,@ViewBuilder content:()->V)->some View {
        VStack(alignment:.leading,spacing:5){Text(title).font(.system(size:10)).foregroundStyle(.secondary);content()}
    }
}

private struct PlaybackTimeReadout: View {
    @ObservedObject var telemetry: PlaybackTelemetry
    var body:some View {
        Text(telemetry.timeLabel).font(.system(size:11,design:.monospaced)).monospacedDigit()
            .frame(width:76,alignment:.leading).accessibilityIdentifier("playbackTime")
    }
}

private struct FrameRateReadout: View {
    @ObservedObject var telemetry: PlaybackTelemetry
    let isOutput:Bool
    let enabled:Bool
    private var title:String { isOutput ? "출력" : "미리보기" }
    private var value:Double? { isOutput ? telemetry.outputFPS : telemetry.previewFPS }
    private var id:String { isOutput ? "outputFPS" : "previewFPS" }
    private var number:String { enabled ? value.map {String(format:"%.1f",$0)} ?? "—" : "—" }
    var body:some View {
        VStack(alignment:.trailing,spacing:1) {
            Text(title).font(.system(size:8)).foregroundStyle(.secondary)
            Text(number+" FPS").font(.system(size:13,weight:.semibold,design:.monospaced))
                .foregroundStyle(enabled && value != nil ? (value == 0 ? Color.orange : .primary) : .secondary)
        }.frame(width:92,alignment:.trailing)
            .accessibilityElement(children:.ignore).accessibilityLabel(title+" "+number+" FPS")
            .accessibilityIdentifier(id)
            .help(enabled
                ? "최근 약 1초간 GPU가 그리기를 완료한 프레임 수입니다. 모니터·LED의 수신 주사율과는 다를 수 있습니다. 일시정지 중에도 화면을 계속 그리므로 FPS는 유지될 수 있습니다."
                : (isOutput ? "출력 시작 후 별도 출력 화면의 FPS를 표시합니다." : "프리뷰 렌더링이 꺼져 있습니다."))
    }
}

private struct PatternPicker:View {
    @ObservedObject var model:OrbitModel
    let names=["구간 번호 / 방향","픽셀 그리드","구간 1–5 + 안팎 띠","RGB","16단계 회색","화이트","블랙","이동 마커","구간 이음새","1픽셀 체크","안쪽만 · 구간색 + 빨강 띠","바깥쪽만 · 구간색 + 파랑 띠"]
    var body:some View {
        Picker("테스트",selection:Binding(get:{Int(model.value("testPattern"))},set:{model.setValue("testPattern",Float($0))})) {
            ForEach(names.indices,id:\.self){Text(names[$0]).tag($0)}
        }.accessibilityIdentifier("calibrationPattern")
    }
}
struct AcceptFirstClick:ViewModifier {
    @ViewBuilder func body(content:Content)->some View {
        if #available(macOS 15.0,*) {content.allowsWindowActivationEvents(true)} else {content}
    }
}
