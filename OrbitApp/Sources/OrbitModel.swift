import AppKit
import Combine
import QuartzCore

struct SceneDescriptor: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String
    let fragmentFunction: String
    let defaults: [String: Float]
    let defaultClockSpeed: Float
    let testScene: Bool
    let referenceSeconds: [Double]?
    let referenceImage: String?
    let texture: TextureDescriptor?
    let parameters: [ShaderParameter]
    let compatibilityParameters: [ShaderParameter]?
    var allParameters: [ShaderParameter] { parameters + (compatibilityParameters ?? []) }
    var hasReference: Bool { referenceImage != nil || referenceSeconds != nil }
}
struct SceneManifest: Decodable { let scenes: [SceneDescriptor] }

struct StoredSettings: Codable {
    var sensors: [SensorInput]
    var scenes: [String: SceneSettings]
    var port: String
    var motionRevision: Int?
    var rendererRevision: Int?
    var outputResolution: OutputResolution?
    var customOutputWidth: Int?
    var installation: InstallationSettings?
    var globalOSC: [GlobalOSCMapping]?
    var oscOutputDestination: OSCOutputDestination?
}
struct OutputDisplay: Identifiable {
    let id: UInt32
    let name: String
    let pixels: String
    let isMain: Bool
    let uuid: String
}

final class OrbitModel: ObservableObject {
    @Published var scenes: [SceneDescriptor] = []
    @Published var selectedSceneID = "07_spectral_fragments" {
        didSet { comparison.stop(); textureSource?.reset(); textureStatus = "텍스처 준비 중"; restartPlayback(); resetParameterState(); scheduleSave() }
    }
    @Published var settings: [String: SceneSettings] = [:]
    // Decode old installation files only; live inputs are addressed directly.
    @Published var sensors: [SensorInput] = []
    @Published var port = "9000" { didSet { scheduleSave() } }
    @Published private(set) var oscOutputDestination = OSCOutputDestination()
    @Published var oscState = "수신 꺼짐"
    @Published var oscRunning = false
    // The compact status bar samples traffic without relaying every packet to the entire UI.
    private(set) var lastMessage = "OSC 데이터 대기"
    private(set) var lastOSCReceivedAt: Date?
    private(set) var lastControlDelivery: ControlDelivery?
    @Published var playing = true { didSet { lastTime = CACurrentMediaTime(); scheduleSave() } }
    @Published var frameRate: PlaybackFrameRate = .sixty { didSet { scheduleSave() } }
    @Published var previewPolicy: PreviewPolicy = .always {
        didSet { if !previewsEnabled { comparison.stop(); previewSurfaces.removeAll(); previewRate.reset() }; scheduleSave() }
    }
    @Published var resumeOnLaunch = true { didSet { scheduleSave() } }
    @Published var globalOSC: [GlobalOSCMapping] = [] { didSet { scheduleSave() } }
    @Published private(set) var globalReceipts: [UUID:OSCReceipt] = [:]
    private(set) var directOSCReceipts: [String:OSCReceipt] = [:]
    private var sampledOutputValues: [String:Double] = [:]
    func latestOSCInput(for keys: [String]) -> OSCReceipt? {
        guard oscRunning,!isShuttingDown else {return nil}
        return keys.compactMap {directOSCReceipts[$0]}.max {$0.receivedAt < $1.receivedAt}
    }
    @Published var showReference = false {
        didSet { if showReference { restartPlayback() } else { comparison.stop() } }
    }
    @Published var errorMessage: String?
    @Published var displays: [OutputDisplay] = []
    @Published var selectedDisplayID: UInt32 = 0 {
        didSet {
            guard !refreshingDisplays, !restoringSettings else { return }
            preferredDisplayUUID = displays.first { $0.id == selectedDisplayID }?.uuid
            displayFallback = false
            if oldValue != selectedDisplayID { stopOutput() }
            scheduleSave()
        }
    }
    @Published private(set) var displayFallback = false
    @Published var outputActive = false
    @Published private(set) var outputOpen = false
    @Published private(set) var outputFullscreen = false
    @Published private(set) var outputRenderSize: CGSize = .zero
    @Published private(set) var outputScreenName = ""
    @Published var outputResolution: OutputResolution = .automatic
    @Published var customOutputWidth: Int = 1920
    @Published var outputStatus = "출력 꺼짐"
    @Published var textureStatus = "텍스처 준비 중"
    @Published private(set) var parameterValues: [String:Double] = [:]
    // Internal engine lifecycle only. The operator enables each output on its own route.
    @Published var controlOutputEnabled = false {
        didSet {
            if updateInstallationInProgress && controlOutputEnabled { controlOutputEnabled = false }
            sampledOutputValues.removeAll()
            controlOutput.reset(); controlOutputStatus = controlOutputEnabled ? "OSC 송신 준비" : "OSC 송신 정지"
            scheduleSave()
        }
    }
    var updateInstallationInProgress = false
    @Published var controlOutputStatus = "OSC 송신 준비 중"
    // Status views poll receipts independently; a network packet must not relayout Metal views.
    private(set) var controlDeliveries: [String:ControlDelivery] = [:]
    let receiver = OSCReceiver()
    let telemetry = PlaybackTelemetry()
    let performance = PerformanceMeasurement()
    private var previewSurfaces: [Float:BenchmarkSurface] = [:]
    let controlOutput: ControlOutput
    let comparison = ComparisonPlayback()
    let textureSource = OrbitGPU.shared.device.map { OrbitTextureSource(device:$0) }
    private var phaseTime: Double = 0
    private var pulseOrbit = PulseOrbitSimulation()
    private var lastPulseCrossing: PulseOrbitSimulation.Crossing?
    private var pulseCueGate = PulseCueGate()
    private(set) var lastPulseAccentAngle = 0.0
    private(set) var lastPulseAccentStrength = 0.0
    var pulseAccentCount: Int {pulseOrbit.accents.count}
    private(set) var pulseCrossingCount = 0
    private var lastTime = CACurrentMediaTime()
    private var parameterResolver = ParameterResolver()
    private var parameterEvents = ParameterEvents()
    private var globalThresholds: [UUID:ThresholdLatch] = [:]
    private var globalThresholdRoutes: [UUID:GlobalOSCMapping] = [:]
    private var controlTimer: Timer?
    private var lastControlTime = CACurrentMediaTime()
    private var outputController: OrbitOutputWindowController?
    private var outputPresentationTime: CFTimeInterval = 0
    private var previewRate = FrameRateMeter()
    private var outputRate = FrameRateMeter()
    private var displayObserver: NSObjectProtocol?
    private var heartbeat: Timer?
    private var saves = Set<AnyCancellable>()
    private var restoringSettings = true
    private var refreshingDisplays = false
    private var preferredDisplayUUID: String?
    private var startupSession: InstallationSettings?
    private var sessionRestored = false
    private var pendingSave: DispatchWorkItem?
    private var oscSessionID = UUID()
    private(set) var isShuttingDown = false
    private let defaults: UserDefaults
    private let resources: Bundle
    var previewsEnabled: Bool { previewPolicy.renders(outputOpen:outputOpen,fullscreen:outputFullscreen) }

    var selectedScene: SceneDescriptor? { scenes.first { $0.id == selectedSceneID } }
    var activeSettings: SceneSettings {
        settings[selectedSceneID] ?? SceneSettings(values: [:], speed: 1)
    }
    var usesTexture: Bool { selectedScene?.texture != nil && (activeSettings.useTexture ?? false) }
    var renderStyle: Int { usesTexture ? 1 : 0 }
    var activeRoutes: [String:ParameterRoute] {
        ((usesTexture ? activeSettings.textureParameterRoutes : activeSettings.parameterRoutes) ?? [:]).mapValues(effectiveRoute)
    }
    func effectiveRoute(_ saved: ParameterRoute) -> ParameterRoute {
        var result=saved;result.output=oscOutputDestination.applying(to:saved.output)
        result.input=saved.input.addressOnly(using:sensors);return result
    }
    var shaderParameters: [ShaderParameter] { usesTexture ? [] : (selectedScene?.parameters ?? []) }
    var allShaderParameters: [ShaderParameter] { usesTexture ? [] : (selectedScene?.allParameters ?? []) }
    var connectedCompatibilityParameters: [ShaderParameter] {
        (selectedScene?.compatibilityParameters ?? []).filter {
            let route = activeRoutes[$0.id]
            return route?.input.enabled == true || route?.output.enabled == true
        }
    }
    private func continuousSpecs(scene: SceneDescriptor, textured: Bool) -> [ParameterSpec] {
        if textured || scene.testScene {return ParameterSpec.all}
        let excluded=["density","turbulence","energy","rotation"]+(scene.id == PulseOrbitSimulation.sceneID ? ["hueShift"] : [])
        return ParameterSpec.all.filter {!excluded.contains($0.id)} + scene.allParameters.enumerated().map {$0.element.spec(index:$0.offset)}
            + (scene.id == PulseOrbitSimulation.sceneID ? PulseOrbitOutputs.specs : [])
    }
    func triggers(for sceneID: String, textured: Bool) -> [SceneTrigger] {
        guard let scene=scenes.first(where:{$0.id==sceneID}),!scene.testScene else {return []}
        let routes=(textured ? settings[sceneID]?.textureParameterRoutes : settings[sceneID]?.parameterRoutes) ?? [:]
        let catalog=SceneTrigger.catalog(scene:sceneID,textured:textured)
        return sceneID == PulseOrbitSimulation.sceneID && !textured ? catalog : catalog+SceneTrigger.converted(routes:routes,specs:continuousSpecs(scene:scene,textured:textured))
    }
    var sceneTriggers: [SceneTrigger] {triggers(for:selectedSceneID,textured:usesTexture)}
    func specs(for sceneID: String, textured: Bool) -> [ParameterSpec] {
        guard let scene=scenes.first(where:{$0.id==sceneID}) else {return []}
        return continuousSpecs(scene:scene,textured:textured)+triggers(for:sceneID,textured:textured).map(\.spec)
    }
    var parameterSpecs: [ParameterSpec] {specs(for:selectedSceneID,textured:usesTexture)}
    func parameterSpec(_ key: String) -> ParameterSpec { parameterSpecs.first { $0.id == key } ?? .find(key) }
    func parameterSpec(_ key: String, sceneID: String, textured: Bool) -> ParameterSpec {
        specs(for:sceneID,textured:textured).first { $0.id == key } ?? .find(key)
    }
    var manualPlaybackSpeed: Float { usesTexture ? (activeSettings.values["texture.speed"] ?? 1) : activeSettings.speed }
    var playbackSpeed: Float { Float(parameterValues["speed"] ?? Double(manualPlaybackSpeed)) }
    var activeControlOutputCount: Int {
        guard selectedScene?.testScene == false else {return 0}
        return parameterSpecs.filter {route(for:$0.id).output.enabled}.count
    }
    var hasActiveControlOutput: Bool {controlOutputEnabled && activeControlOutputCount > 0}
    var blocksUpdateInstallation: Bool {outputOpen || hasActiveControlOutput || performance.isRunning}
    var outputParameterSpecs: [ParameterSpec] {
        guard selectedScene?.testScene == false else { return [] }
        return parameterSpecs.filter { spec in
            guard let route = activeRoutes[spec.id]?.output else { return false }
            return route.isListed(defaultRoute:oscOutputDestination.applying(to:ParameterRoute.defaults(scene:selectedSceneID,parameter:spec.id,spec:spec).output))
        }
    }
    func controlEmissionID(_ key: String) -> String { "\(selectedSceneID):\(renderStyle):\(key)" }
    func controlDelivery(for key: String) -> ControlDelivery? {
        controlDelivery(for:key,sceneID:selectedSceneID,textured:usesTexture)
    }
    func controlDelivery(for key: String, sceneID: String, textured: Bool) -> ControlDelivery? {
        guard let delivery = controlDeliveries["\(sceneID):\(textured ? 1 : 0):\(key)"],
              delivery.destination == route(for:key,sceneID:sceneID,textured:textured).output.destinationKey else { return nil }
        return delivery
    }
    func clearControlOutput(_ key: String) {
        clearControlOutput(key,sceneID:selectedSceneID,textured:usesTexture)
    }
    func clearControlOutput(_ key: String, sceneID: String, textured: Bool) {
        let original = ParameterRoute.defaults(scene:sceneID,parameter:key,spec:parameterSpec(key,sceneID:sceneID,textured:textured)).output
        controlDeliveries.removeValue(forKey:"\(sceneID):\(textured ? 1 : 0):\(key)")
        setRoute(key,sceneID:sceneID,textured:textured) { $0.output = original }
    }
    private let textureDefaults: [String: Float] = ["density":0.5,"turbulence":0,"energy":0,
        "hueShift":0,"brightness":1,"coverage":1,"gapSoftness":0.8,"gapMotion":0.25,"fragmentation":0,"rotation":0,
        "generation":0.72,"sharpness":0.45,"evolution":0.55,"detail":0.65]
    var effectiveValues: [String: Float] {
        var values = activeSettings.values
        if usesTexture {
            for (name, fallback) in textureDefaults { values[name] = values["texture." + name] ?? fallback }
            values["testPattern"] = selectedScene?.texture?.kind == "image" ? 1 : 0
            values["markerWidth"] = (values["rotation"] ?? 0.1) * 0.1
        }
        return values
    }
    var outputName: String { outputOpen ? outputScreenName : (displays.first { $0.id == selectedDisplayID }?.name ?? "현재 화면") }
    var outputSizeLabel: String {
        if outputOpen, outputRenderSize.width > 0 { return OutputGeometry.label(outputRenderSize) }
        if outputResolution == .automatic { return "자동 · 16:9" }
        return OutputGeometry.label(outputResolution.size(availablePixels: .zero, customWidth: customOutputWidth))
    }
    var customOutputHeight: Int { OutputGeometry.normalizedWidth(customOutputWidth)/16*9 }
    func normalizeOutputWidth() { customOutputWidth = OutputGeometry.normalizedWidth(customOutputWidth) }

    init(defaults: UserDefaults = .standard, resources: Bundle = .main, controlOutput: ControlOutput = ControlOutput()) {
        self.controlOutput = controlOutput
        self.defaults = defaults; self.resources = resources
        do {
            guard let url = resources.url(forResource: "scenes", withExtension: "json", subdirectory: "config") else {
                throw NSError(domain: "Orbit", code: 1, userInfo: [NSLocalizedDescriptionKey: "씬 목록이 앱에 포함되지 않았습니다."])
            }
            let manifest = try JSONDecoder().decode(SceneManifest.self, from: Data(contentsOf: url))
            scenes = manifest.scenes.filter { !$0.testScene } + manifest.scenes.filter { $0.testScene }
            for scene in scenes { settings[scene.id] = SceneSettings(values: scene.defaults, speed: scene.defaultClockSpeed) }
            globalOSC = scenes.map { GlobalOSCMapping(address:"/orbit/scene/"+$0.id, action:.scene, sceneID:$0.id) }
                + [GlobalOSCMapping(address:"/orbit/scene/next",action:.next),
                   GlobalOSCMapping(address:"/orbit/scene/previous",action:.previous),
                   GlobalOSCMapping(address:"/orbit/restart",action:.restart),
                   GlobalOSCMapping(address:"/orbit/play",action:.play),
                   GlobalOSCMapping(address:"/orbit/pause",action:.pause)]
            if let data = defaults.data(forKey: "OrbitSettings.v1"),
               let stored = try? JSONDecoder().decode(StoredSettings.self, from: data) {
                if !stored.sensors.isEmpty,defaults.data(forKey:"OrbitSettings.beforeAddressOnly.v1") == nil {
                    defaults.set(data,forKey:"OrbitSettings.beforeAddressOnly.v1")
                }
                sensors = stored.sensors.map { var s = $0; s.receivedAt = nil; s.value = nil; s.minimum = 0; s.maximum = 1; return s }
                for (key, storedValue) in stored.scenes where settings[key] != nil {
                    var value = storedValue
                    value.migrateRoutes(scene:key)
                    value.migrateShaderParameters(scenes.first { $0.id == key }?.allParameters ?? [])
                    settings[key]?.values.merge(value.values) { _, storedValue in storedValue }
                    settings[key]?.speed = value.speed
                    settings[key]?.mapping = value.mapping
                    settings[key]?.useTexture = stored.rendererRevision == 3 ? value.useTexture : false
                    settings[key]?.textureMapping = value.textureMapping
                    settings[key]?.parameterRoutes = value.parameterRoutes
                    settings[key]?.textureParameterRoutes = value.textureParameterRoutes
                    if stored.motionRevision != 2 {
                        // Migrate only the old supplied defaults; preserve deliberate user adjustments.
                        let oldSpeeds: [String: Float] = ["01_chroma_flow":0.75,"02_solar_bands":0.65,
                            "03_aurora_ribbon":0.70,"04_electric_corona":0.85,"05_cyan_halo":0.60]
                        let oldPresence: [String: [Float]] = ["01_chroma_flow":[0.72,0.80,0.25,0.08],
                            "02_solar_bands":[0.94,0.35,0.30,0.14],"03_aurora_ribbon":[0.82,0.75,0.30,0.06],
                            "04_electric_corona":[0.91,0.35,0.40,0.25],"05_cyan_halo":[0.68,0.90,0.25,0],
                            "07_spectral_fragments":[0.93,0.25,0.35,0.35]]
                        if let old = oldSpeeds[key], abs(value.speed - old) < 0.0001 {
                            settings[key]?.speed = 1
                        }
                        if let old = oldPresence[key], let scene = scenes.first(where: { $0.id == key }) {
                            for (i, name) in ["coverage","gapSoftness","gapMotion","fragmentation"].enumerated() {
                                if let saved = value.values[name], abs(saved - old[i]) < 0.0001 {
                                    settings[key]?.values[name] = scene.defaults[name]
                                }
                            }
                        }
                    }
                }
                port = stored.port
                outputResolution = stored.outputResolution ?? .automatic
                customOutputWidth = OutputGeometry.normalizedWidth(stored.customOutputWidth ?? 1920)
                let builtinGlobalRoutes=globalOSC
                globalOSC = stored.globalOSC ?? builtinGlobalRoutes
                // The catalog follows actual app actions. Preserve custom addresses and old aliases.
                for builtin in builtinGlobalRoutes where !globalOSC.contains(where: {
                    $0.action == builtin.action && (builtin.action != .scene || $0.sceneID == builtin.sceneID)
                }) {
                    globalOSC.append(builtin)
                }
                startupSession = stored.installation
                preferredDisplayUUID = stored.installation?.displayUUID
                if let id = stored.installation?.selectedSceneID, scenes.contains(where: { $0.id == id }) { selectedSceneID = id }
                if let rate = stored.installation?.frameRate { frameRate = PlaybackFrameRate(rawValue:rate) ?? .sixty }
                previewPolicy = stored.installation?.previewPolicy ?? .always
                playing = stored.installation?.playing ?? true
                resumeOnLaunch = stored.installation?.resumeOnLaunch ?? true
                let orderedIDs=[selectedSceneID]+settings.keys.sorted().filter {$0 != selectedSceneID}
                let legacyOutputs=orderedIDs.flatMap {id -> [ParameterOutputRoute] in
                    let scene=settings[id]
                    let sources=scene?.useTexture == true ? [scene?.textureParameterRoutes,scene?.parameterRoutes] : [scene?.parameterRoutes,scene?.textureParameterRoutes]
                    return sources.flatMap {routes in (routes ?? [:]).sorted {$0.key < $1.key}.map { $0.value.output }}
                }
                oscOutputDestination=stored.oscOutputDestination ?? .migrated(from:legacyOutputs)
            }
        } catch { errorMessage = error.localizedDescription }
        for scene in scenes {
            settings[scene.id]?.migrateRoutes(scene:scene.id)
            settings[scene.id]?.migrateOSCOutputs()
            for textured in [false,true] {
                settings[scene.id]?.separateTriggerRoutes(scene:scene.id,specs:continuousSpecs(scene:scene,textured:textured),textured:textured)
            }
            settings[scene.id]?.migrateOSCInputs(using:sensors)
        }
        sensors=[]
        textureSource?.onReady = { [weak self] in self?.textureStatus = "텍스처 재생 준비됨" }
        textureSource?.onError = { [weak self] message in
            self?.textureStatus = "텍스처 읽기 실패"; self?.errorMessage = message
        }
        refreshDisplays()
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refreshDisplays() }
        let presentationTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            self.telemetry.updateFPS(preview:self.previewRate.framesPerSecond(at:now),
                                     output:self.outputOpen ? self.outputRate.framesPerSecond(at:now) : nil)
            if self.outputController != nil && now - self.outputPresentationTime > 1 {
                self.outputActive = false; self.outputStatus = "출력 프레임 대기"
            }
        }
        RunLoop.main.add(presentationTimer,forMode:.common); heartbeat = presentationTimer
        $settings.dropFirst().debounce(for: .milliseconds(400), scheduler: RunLoop.main).sink { [weak self] _ in self?.save() }.store(in: &saves)
        $sensors.dropFirst().debounce(for: .milliseconds(400), scheduler: RunLoop.main).sink { [weak self] _ in self?.save() }.store(in: &saves)
        $outputResolution.combineLatest($customOutputWidth).dropFirst()
            .sink { [weak self] resolution,width in
                self?.outputController?.configure(resolution: resolution, customWidth: width)
            }.store(in: &saves)
        $outputResolution.combineLatest($customOutputWidth).dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }.store(in: &saves)
        controlOutput.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.controlOutputEnabled || status.contains("테스트") || status.contains("준비") || status.contains("실패") {
                    self.controlOutputStatus = status
                }
            }
        }
        controlOutput.onDelivery = { [weak self] delivery in
            DispatchQueue.main.async {
                self?.controlDeliveries[delivery.id] = delivery
                self?.lastControlDelivery = delivery
            }
        }
        refreshParameters(delta:0)
        let timer = Timer(timeInterval:1.0/30.0,repeats:true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            self.refreshParameters(delta:max(0,now-self.lastControlTime)); self.lastControlTime = now
        }
        RunLoop.main.add(timer,forMode:.common); controlTimer = timer
        restoringSettings = false
    }

    private func scheduleSave() {
        guard !restoringSettings, !isShuttingDown else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25,execute:item)
    }
    func save() {
        guard !restoringSettings, !isShuttingDown else { return }
        let installation = InstallationSettings(displayUUID:preferredDisplayUUID,selectedSceneID:selectedSceneID,
            frameRate:frameRate.rawValue,previewPolicy:previewPolicy,playing:playing,resumeOnLaunch:resumeOnLaunch,
            oscReceiving:oscRunning,controlSending:controlOutputEnabled,outputOpen:outputOpen,outputFullscreen:outputFullscreen)
        let persistedSensors = sensors.map { sensor -> SensorInput in
            var s = sensor; s.value = nil; s.receivedAt = nil; return s
        }
        let data = try? JSONEncoder().encode(StoredSettings(sensors: persistedSensors, scenes: settings, port: port, motionRevision: 2, rendererRevision: 3, outputResolution: outputResolution, customOutputWidth: customOutputWidth, installation:installation, globalOSC:globalOSC,oscOutputDestination:oscOutputDestination))
        if let data { defaults.set(data, forKey: "OrbitSettings.v1") }
    }
    func restoreSessionOnce() {
        guard !sessionRestored, !isShuttingDown, !updateInstallationInProgress else { return }; sessionRestored = true
        // OSC is ready on every launch; per-route switches are the only user-facing gates.
        startOSC()
        controlOutputEnabled = true
        guard resumeOnLaunch, let session = startupSession else { return }
        startupSession = nil
        if session.outputOpen == true {
            startOutput()
            if session.outputFullscreen == true {
                DispatchQueue.main.async { [weak self] in self?.toggleOutputFullscreen() }
            }
        }
    }
    /// Live simulation signals stay outside the published shader-control dictionary.
    func controlValue(_ key: String) -> Double {
        if key.hasPrefix("trigger.") { return triggerLevels()[key] ?? 0 }
        if selectedSceneID == PulseOrbitSimulation.sceneID {
            switch key {
            case PulseOrbitOutputs.trigger: return lastPulseCrossing.map { pulseOrbit.time-$0.time < 0.1 ? 1 : 0 } ?? 0
            case PulseOrbitOutputs.angle: return lastPulseCrossing?.angle ?? 0
            case PulseOrbitOutputs.strength: return lastPulseCrossing?.strength ?? 0
            case PulseOrbitOutputs.proximity: return pulseOrbit.proximity
            case PulseOrbitOutputs.accentAngle: return lastPulseAccentAngle
            case PulseOrbitOutputs.accentStrength: return lastPulseAccentStrength
            default: break
            }
        }
        return parameterValues[key] ?? baseParameterValue(key)
    }
    func value(_ name: String) -> Float { Float(parameterValues[name] ?? Double(effectiveValues[name] ?? 0)) }
    func baseParameterValue(_ key: String) -> Double { key == "speed" ? Double(manualPlaybackSpeed) : Double(effectiveValues[key] ?? 0) }
    func baseParameterValue(_ key: String, sceneID: String, textured: Bool) -> Double {
        guard let scene=settings[sceneID] else {return 0}
        if key == "speed" {return Double(textured ? scene.values["texture.speed"] ?? 1 : scene.speed)}
        if textured, let fallback=textureDefaults[key] {return Double(scene.values["texture."+key] ?? fallback)}
        return Double(scene.values[key] ?? 0)
    }
    func normalizedParameterValue(_ key: String) -> Double {
        parameterSpec(key).normalized(controlValue(key))
    }
    func setNormalizedParameterValue(_ key: String, _ value: Double) {
        setNormalizedParameterValue(key,value,sceneID:selectedSceneID,textured:usesTexture)
    }
    func setNormalizedParameterValue(_ key: String, _ value: Double, sceneID: String, textured: Bool) {
        let spec=parameterSpec(key,sceneID:sceneID,textured:textured)
        guard !spec.outputOnly,!spec.isTrigger,var scene=settings[sceneID] else {return}
        let previous=baseParameterValue(key,sceneID:sceneID,textured:textured)
        let raw=Float(spec.rawValue(normalized:value))
        if key == "speed" && !textured {scene.speed=raw}
        else {scene.values[textured && (key == "speed" || textureDefaults[key] != nil) ? "texture."+key : key]=raw}
        settings[sceneID]=scene
        if sceneID == selectedSceneID && textured == usesTexture {
            directOSCReceipts.removeValue(forKey:key);refreshParameters(delta:0)
            if previous != Double(raw) {sendContinuousInputTriggers([key])}
        }
    }
    /// Snapshot the live session before cleanup so reopening can restore it. Cleanup must not save an empty session.
    func shutdownForTermination() {
        guard !isShuttingDown else { return }
        save(); isShuttingDown = true
        pendingSave?.cancel(); pendingSave = nil; saves.removeAll()
        controlTimer?.invalidate(); controlTimer = nil
        heartbeat?.invalidate(); heartbeat = nil
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver); self.displayObserver = nil }
        performance.cancel()
        stopOSC(); receiver.onMessage = nil; receiver.onState = nil
        controlOutputEnabled = false
        comparison.stop(); textureSource?.reset()
        stopOutput()
    }
    func setValue(_ name: String, _ value: Float) {
        guard value.isFinite, !parameterSpec(name).outputOnly,!parameterSpec(name).isTrigger else { return }
        let key = usesTexture && textureDefaults[name] != nil ? "texture." + name : name
        settings[selectedSceneID]?.values[key] = value
        refreshParameters(delta:0)
    }
    func setSpeed(_ speed: Float) {
        if usesTexture { settings[selectedSceneID]?.values["texture.speed"] = speed }
        else { settings[selectedSceneID]?.speed = speed }
        refreshParameters(delta:0)
    }
    func setTextureMode(_ enabled: Bool) {
        settings[selectedSceneID]?.useTexture = enabled
        textureSource?.reset(); textureStatus = "텍스처 준비 중"
        comparison.stop(); restartPlayback(); resetParameterState()
    }
    func setRenderStyle(_ style: Int) {
        setTextureMode(style == 1)
    }
    func restartPlayback() {
        parameterEvents.reset()
        phaseTime = 0; lastTime = CACurrentMediaTime()
        pulseOrbit = PulseOrbitSimulation()
        pulseCueGate = PulseCueGate();lastPulseAccentAngle=0;lastPulseAccentStrength=0
        lastPulseCrossing = nil; pulseCrossingCount = 0
        telemetry.updateTime(0,force:true)
        comparison.invalidatePosition()
    }
    func resetSceneAppearance() {
        guard let scene = selectedScene else { return }
        var updated = activeSettings
        if usesTexture {
            for (name, value) in textureDefaults { updated.values["texture." + name] = value }
            updated.values["texture.speed"] = 1
            settings[selectedSceneID] = updated
            restartPlayback(); resetParameterState()
            return
        }
        // Keep the installation's orientation and sensor routing intact.
        let appearance = ["density", "turbulence", "energy", "hueShift", "brightness", "seed",
                          "coverage", "gapSoftness", "gapMotion", "fragmentation"]
        for name in appearance { updated.values[name] = scene.defaults[name] }
        for parameter in scene.allParameters { updated.values[parameter.id] = Float(parameter.defaultValue) }
        updated.speed = scene.defaultClockSpeed
        settings[selectedSceneID] = updated
        restartPlayback(); resetParameterState()
    }
    func route(for key: String) -> ParameterRoute {
        route(for:key,sceneID:selectedSceneID,textured:usesTexture)
    }
    func route(for key: String, sceneID: String, textured: Bool) -> ParameterRoute {
        let routes=textured ? settings[sceneID]?.textureParameterRoutes : settings[sceneID]?.parameterRoutes
        return effectiveRoute(routes?[key] ?? ParameterRoute.defaults(scene:sceneID,parameter:key,spec:parameterSpec(key,sceneID:sceneID,textured:textured)))
    }
    func inputOSCAddress(_ key: String, sceneID: String, textured: Bool) -> String {
        route(for:key,sceneID:sceneID,textured:textured).input.directOSCAddress
            ?? SceneOSCAddress.input(scene:sceneID,parameter:key,textured:textured)
    }
    func inputOSCIssue(_ key: String, sceneID: String, textured: Bool) -> String? {
        let address=inputOSCAddress(key,sceneID:sceneID,textured:textured)
        guard SceneOSCAddress.isValid(address) else {return "공백·와일드카드 없이 /로 시작하는 OSC 주소를 입력하세요."}
        if globalOSC.contains(where:{$0.enabled && $0.address == address}) {return "글로벌 동작과 주소가 겹칩니다. 다른 주소를 사용하세요."}
        // One address may intentionally drive multiple controls in the active scene.
        return nil
    }
    @discardableResult func setOSCOutputDestination(_ proposed: OSCOutputDestination) -> Bool {
        let destination=proposed.normalized
        guard destination.validationError == nil else {return false}
        guard destination != oscOutputDestination else {return true}
        oscOutputDestination=destination
        controlOutput.reset()
        controlDeliveries=controlDeliveries.filter {!$0.value.destination.hasPrefix("osc:")}
        controlOutputStatus="OSC 출력 대상 · "+destination.label
        scheduleSave();refreshParameters(delta:0)
        return true
    }
    @discardableResult func applyOSCNetworkSettings(receivePort: String, output: OSCOutputDestination) -> Bool {
        guard let number=UInt16(receivePort.trimmingCharacters(in:.whitespacesAndNewlines)),number>0,output.validationError == nil else {return false}
        let newPort=String(number),changed=newPort != port
        if changed {stopOSC()}
        if changed {port=newPort}
        setOSCOutputDestination(output)
        if !oscRunning {startOSC()}
        save()
        return true
    }
    func setRoute(_ key: String, _ update: (inout ParameterRoute) -> Void) {
        setRoute(key,sceneID:selectedSceneID,textured:usesTexture,update)
    }
    /// Overview edits share validation with the parameter buttons, without switching the live scene.
    func setRoute(_ key: String, sceneID: String, textured: Bool, _ update: (inout ParameterRoute) -> Void) {
        guard var scene=settings[sceneID] else {return}
        let active=sceneID == selectedSceneID && textured == usesTexture
        var route = route(for:key,sceneID:sceneID,textured:textured); let prior = route; update(&route)
        route=effectiveRoute(route)
        let spec = parameterSpec(key,sceneID:sceneID,textured:textured)
        if spec.outputOnly { route.input = ParameterInputRoute() }
        if spec.isTrigger {
            route.input.mode = route.input.sourceParameter != nil || route.input.behavior == .threshold ? .threshold : .event
            route.input.minimum=0;route.input.maximum=spec.clamp(route.input.maximum)
            route.output.mode = .event
        } else {
            route.input.mode=nil;route.input.sourceParameter=nil
            if !spec.supportsOutputMode || route.output.behavior != .trigger {route.output.mode=nil}
        }
        if spec.isTrigger || spec.id == PulseOrbitOutputs.trigger {
            route.output.minimum = 0; route.output.maximum = 1
        }
        route.input.minimum = spec.clamp(route.input.minimum)
        route.input.maximum = spec.clamp(route.input.maximum)
        if key == SceneTrigger.addLineID {
            route.input.lineLimit=min(PulseOrbitSimulation.maximumLineCount,max(4,route.input.lineLimit ?? PulseOrbitSimulation.maximumLineCount))
            if active && pulseOrbit.lineCount > route.input.lineLimit! {pulseOrbit.setLineCount(PulseOrbitSimulation.defaultLineCount);lastPulseCrossing=nil}
        }
        if let event=route.input.event { route.input.event=event.sanitized }
        if let threshold=route.output.threshold { route.output.threshold=threshold.sanitized }
        if active && prior.input != route.input { parameterEvents.clear(key);directOSCReceipts.removeValue(forKey:key) }
        if active && prior.output != route.output {sampledOutputValues.removeValue(forKey:key)}
        route.input.smoothingSeconds = route.input.smoothingSeconds.isFinite ? min(30,max(0,route.input.smoothingSeconds)) : 8
        if !route.output.minimum.isFinite { route.output.minimum = prior.output.minimum }
        if !route.output.maximum.isFinite { route.output.maximum = prior.output.maximum }
        var routes=(textured ? scene.textureParameterRoutes : scene.parameterRoutes) ?? [:];routes[key]=route
        if textured { scene.textureParameterRoutes = routes } else { scene.parameterRoutes = routes }
        settings[sceneID] = scene
        if active {refreshParameters(delta:0)}
    }
    func outputIssue(for key: String) -> String? {
        outputIssue(for:key,sceneID:selectedSceneID,textured:usesTexture)
    }
    func outputIssue(for key: String, sceneID: String, textured: Bool) -> String? {
        let route = route(for:key,sceneID:sceneID,textured:textured).output
        if route.transport == .osc,let issue=oscOutputDestination.validationError {return issue}
        if let issue = route.validationError { return issue }
        let routes=(textured ? settings[sceneID]?.textureParameterRoutes : settings[sceneID]?.parameterRoutes) ?? [:]
        let validKeys=Set(specs(for:sceneID,textured:textured).map(\.id))
        if let other = routes.first(where: { validKeys.contains($0.key) && $0.key != key && $0.value.output.enabled && oscOutputDestination.applying(to:$0.value.output).destinationKey == route.destinationKey }) {
            return "\(parameterSpec(other.key,sceneID:sceneID,textured:textured).title)와 출력 주소가 겹칩니다. OSC 주소를 바꾸세요."
        }
        return nil
    }
    func testControlOutput(_ key: String) {
        guard let spec = parameterSpecs.first(where: { $0.id == key }), outputIssue(for:key) == nil else { return }
        // A one-shot test never changes the operator's automatic sending state.
        setRoute(key) { $0.output.configured = true }
        let route = route(for:key).output
        if route.sendsTriggerValue(spec:spec) || (route.sendsEvents(spec:spec) && !spec.eventOutput) {
            sendParameterEvent(key,test:true)
        } else if spec.eventOutput {
            controlOutput.sendEvents(pulseEventEmissions(for:[spec],values:[key:key == PulseOrbitOutputs.trigger ? 1 : controlValue(key)]),test:true)
        } else if let value = route.mappedValue(controlValue(key),spec:spec) {
            controlOutput.send([ControlEmission(id:controlEmissionID(key),route:route,value:value)],force:true)
        }
    }
    private func resetParameterState() {
        directOSCReceipts.removeAll()
        sampledOutputValues.removeAll()
        parameterResolver.reset(); parameterEvents.reset(); controlOutput.reset(); lastControlTime = CACurrentMediaTime()
        refreshParameters(delta:0)
    }
    private func refreshParameters(delta: Double) {
        var base = effectiveValues.mapValues(Double.init); base["speed"] = Double(manualPlaybackSpeed)
        let routes = selectedScene?.testScene == false ? activeRoutes : [:]
        var resolved = parameterResolver.resolve(base:base,routes:routes,sensors:[],now:Date(),delta:delta,specs:parameterSpecs,directInputs:directOSCReceipts)
        if usesTexture { resolved["markerWidth"] = (resolved["rotation"] ?? 0)*0.1 }
        if parameterValues != resolved { parameterValues = resolved }
        for event in sceneTriggers {
            let input=route(for:event.id).input
            guard let source=input.sourceParameter,let spec=parameterSpecs.first(where:{$0.id==source && !$0.isTrigger && !$0.eventOutput}) else {continue}
            if parameterEvents.accepts(event.id,value:spec.normalized(controlValue(source)),route:input,fireFirst:false) {triggerParameter(event.id)}
        }
        deliverContinuousSimulationTriggers()
        guard controlOutputEnabled else { return }
        let emissions = parameterSpecs.compactMap { spec -> ControlEmission? in
            guard let route = routes[spec.id]?.output, !route.sendsEvents(spec:spec), route.enabled, outputIssue(for:spec.id) == nil,
                  let value = route.mappedValue(spec.outputOnly ? controlValue(spec.id) : (resolved[spec.id] ?? baseParameterValue(spec.id)),spec:spec) else { return nil }
            return ControlEmission(id:controlEmissionID(spec.id),route:route,value:value)
        }
        let eventRoutes = parameterSpecs.filter { route(for:$0.id).output.sendsEvents(spec:$0) }.compactMap { spec -> ParameterOutputRoute? in
            let route = routes[spec.id]?.output
            return route?.enabled == true && outputIssue(for:spec.id) == nil ? route : nil
        }
        controlOutput.send(emissions,retaining:eventRoutes)
    }
    /// A valid input packet is a new cue even when its Float repeats or is below 0.5.
    /// Rendering and heartbeat ticks never enter this path.
    private func sendContinuousInputTriggers(_ keys: [String]) {
        guard controlOutputEnabled,!isShuttingDown else {return}
        let emissions=keys.compactMap { key -> ControlEmission? in
            let spec=parameterSpec(key),route=route(for:key).output
            guard !spec.isTrigger,!spec.outputOnly,route.behavior == .trigger,route.enabled,outputIssue(for:key)==nil else {return nil}
            return .init(id:controlEmissionID(key),route:route,value:1)
        }
        // Each external packet is an explicit cue. Only spontaneous crossings
        // use the quiet-scene rate limit; never discard user/sensor commands.
        if !emissions.isEmpty {controlOutput.sendEvents(emissions)}
    }
    /// Output-only continuous simulation sources have no input packets. Emit on
    /// changes between samples, with no cue for the initial value or a held value.
    private func deliverContinuousSimulationTriggers() {
        for spec in parameterSpecs where spec.outputOnly && !spec.eventOutput {
            let value=Float(spec.normalized(controlValue(spec.id)))
            guard value.isFinite else {continue}
            let previous=sampledOutputValues.updateValue(Double(value),forKey:spec.id)
            let route=route(for:spec.id).output
            if controlOutputEnabled,!isShuttingDown,let previous,previous != Double(value),
               route.enabled,route.behavior == .trigger {sendParameterEvent(spec.id)}
        }
    }
    func setInputBehavior(_ key: String, _ mode: ParameterInputMode) {
        guard parameterSpec(key).isTrigger else {return}
        setRoute(key) {$0.input.mode = mode == .threshold ? .threshold : .event}
    }
    var pulseLineCount: Int {pulseOrbit.lineCount}
    var pulseLineLimit: Int {min(PulseOrbitSimulation.maximumLineCount,max(4,route(for:SceneTrigger.addLineID).input.lineLimit ?? PulseOrbitSimulation.maximumLineCount))}
    func parameterEventCount(_ key: String) -> Int { parameterEvents.counts[key] ?? 0 }
    func triggerLevels() -> [String:Double] {
        let events=sceneTriggers
        let routes=Dictionary(uniqueKeysWithValues:events.map {($0.id,activeRoutes[$0.id] ?? ParameterRoute.defaults(scene:selectedSceneID,parameter:$0.id,spec:$0.spec))})
        if selectedSceneID == PulseOrbitSimulation.sceneID,!usesTexture {
            return Dictionary(uniqueKeysWithValues:events.map { event in
                let level=pulseOrbit.accents.filter {$0.kind==pulseAccentKind(event.id)}.map { accent in
                    max(0, min(1, (accent.duration-(pulseOrbit.time-accent.start))/1.2))*accent.strength
                }.max() ?? 0
                return (event.id,level)
            })
        }
        return parameterEvents.apply(Dictionary(uniqueKeysWithValues:events.map {($0.id,0.0)}),routes:routes,specs:events.map(\.spec),at:CACurrentMediaTime())
    }
    /// Trigger IDs are commands, never writable continuous controls.
    func triggerParameter(_ key: String) {
        let spec=parameterSpec(key),route=route(for:key)
        guard selectedScene?.testScene == false,spec.isTrigger,!isShuttingDown else { return }
        if selectedSceneID == PulseOrbitSimulation.sceneID,!usesTexture,
           let kind=pulseAccentKind(key) {
            if key == SceneTrigger.addLineID {pulseOrbit.addLine(limit:pulseLineLimit);lastPulseCrossing=nil}
            let accent=pulseOrbit.accent(kind,controls:.init(drive:Double(value("directionDrive")),attraction:Double(value("attraction")),
                               inertia:Double(value("inertia")),center:Double(value("attractorPosition")),density:Double(value("pulseDensity"))),strength:route.input.maximum)
            lastPulseAccentAngle=accent.origin;lastPulseAccentStrength=accent.strength
        }
        parameterEvents.fire(key,route:route.input,at:CACurrentMediaTime())
        let accentMetadataEnabled=selectedSceneID == PulseOrbitSimulation.sceneID && pulseAccentKind(key) != nil
            && [PulseOrbitOutputs.accentAngle,PulseOrbitOutputs.accentStrength].contains {self.route(for:$0).output.enabled}
        if controlOutputEnabled && (route.output.enabled || accentMetadataEnabled) {sendParameterEvent(key)}
    }
    private func sendParameterEvent(_ key: String, test: Bool = false) {
        let route=route(for:key).output,id=controlEmissionID(key)
        if test,outputIssue(for:key) != nil {return}
        var emissions: [ControlEmission] = (test || route.enabled) && outputIssue(for:key) == nil ? [.init(id:id,route:route,value:1)] : []
        if !test,selectedSceneID == PulseOrbitSimulation.sceneID,!usesTexture,pulseAccentKind(key) != nil {
            let metadata=[PulseOrbitOutputs.accentAngle,PulseOrbitOutputs.accentStrength].compactMap {key in
                parameterSpecs.first {$0.id==key && self.route(for:key).output.enabled}
            }
            emissions=pulseEventEmissions(for:metadata,values:[PulseOrbitOutputs.accentAngle:lastPulseAccentAngle,
                     PulseOrbitOutputs.accentStrength:lastPulseAccentStrength])+emissions
        }
        guard !emissions.isEmpty else {return}
        controlOutput.sendEvents(emissions,test:test)
    }
    private func pulseAccentKind(_ key: String) -> PulseOrbitSimulation.AccentKind? {
        switch key {
        case SceneTrigger.departureID:return .departure
        case SceneTrigger.breakthroughID:return .breakthrough
        case SceneTrigger.addLineID:return .newOrbit
        case SceneTrigger.completionID:return .completion
        default:return nil
        }
    }
    private func acceptsPulseCue() -> Bool {
        guard selectedSceneID == PulseOrbitSimulation.sceneID,!usesTexture else {return true}
        return pulseCueGate.accept(at:CACurrentMediaTime())
    }
    private func pulseEventEmissions(for specs: [ParameterSpec], values: [String:Double]) -> [ControlEmission] {
        specs.flatMap { spec -> [ControlEmission] in
            let route = route(for:spec.id).output
            guard outputIssue(for:spec.id) == nil, let raw = values[spec.id], let mapped = route.mappedValue(raw,spec:spec) else { return [] }
            let value=route.sendsTriggerValue(spec:spec) ? 1 : mapped
            let event = ControlEmission(id:controlEmissionID(spec.id),route:route,value:value)
            return [event]
        }
    }
    private func deliverPulseCrossings() {
        for crossing in pulseOrbit.takeCrossings() {
            lastPulseCrossing = crossing; pulseCrossingCount += 1
            guard controlOutputEnabled, !isShuttingDown else { continue }
            // Metadata first, then trigger; OSC bundles keep all selected fields in one datagram.
            let specs = [PulseOrbitOutputs.angle,PulseOrbitOutputs.strength,PulseOrbitOutputs.trigger].compactMap { key in
                parameterSpecs.first { $0.id == key && route(for:key).output.enabled }
            }
            let values = [PulseOrbitOutputs.trigger:1, PulseOrbitOutputs.angle:crossing.angle, PulseOrbitOutputs.strength:crossing.strength]
            let emissions=pulseEventEmissions(for:specs,values:values)
            if !emissions.isEmpty && acceptsPulseCue() {controlOutput.sendEvents(emissions)}
        }
    }
    func startOSC() {
        guard !isShuttingDown else { return }
        guard let number = UInt16(port), number > 0 else { errorMessage = "UDP 포트는 1–65535 범위여야 합니다."; return }
        let session=UUID();oscSessionID=session
        receiver.onState = { [weak self] running, message in
            DispatchQueue.main.async {
                guard let self, self.oscSessionID == session else { return }
                self.oscRunning = running; self.oscState = message; self.scheduleSave()
            }
        }
        receiver.onMessage = { [weak self] address, values in
            DispatchQueue.main.async {
                guard let self, self.oscSessionID == session else { return }
                self.receiveOSC(address:address,values:values)
            }
        }
        receiver.start(port: number); save()
    }
    func stopOSC() { directOSCReceipts.removeAll();globalThresholds.removeAll();globalThresholdRoutes.removeAll();parameterEvents.reset();oscSessionID=UUID();receiver.stop(); oscRunning = false; oscState = "수신 꺼짐"; scheduleSave() }

    func receiveOSC(address: String, values: [Double]) {
        guard !isShuttingDown else { return }
        let receivedAt=Date()
        lastOSCReceivedAt = receivedAt
        lastMessage = address + "  " + values.map { OSCValue.normalized($0).map { String(format:"%.2f",$0) } ?? "실수 필요" }.joined(separator:", ")
        var receivedContinuous: [String] = []
        // A packet's address and Float arguments are the complete external input contract.
        if selectedScene?.testScene == false {
            for spec in parameterSpecs where !spec.outputOnly {
                let input=route(for:spec.id).input
                guard input.receivesDirectOSC,inputOSCAddress(spec.id,sceneID:selectedSceneID,textured:usesTexture)==address,
                      inputOSCIssue(spec.id,sceneID:selectedSceneID,textured:usesTexture)==nil,
                      values.indices.contains(input.oscArgument),let value=OSCValue.normalized(values[input.oscArgument]) else {continue}
                let previous=directOSCReceipts[spec.id]
                directOSCReceipts[spec.id]=OSCReceipt(value:value,receivedAt:receivedAt,
                    triggerCount:(previous?.triggerCount ?? 0)+(spec.isTrigger && value>=0.5 ? 1 : 0),
                    packetCount:(previous?.packetCount ?? 0)+1)
                if spec.isTrigger {
                    if value>=0.5 {triggerParameter(spec.id)}
                } else if var scene=settings[selectedSceneID] {
                    let rawValue=Float(spec.rawValue(normalized:value))
                    if spec.id=="speed" && !usesTexture {scene.speed=rawValue}
                    else {scene.values[usesTexture && (spec.id=="speed" || textureDefaults[spec.id] != nil) ? "texture."+spec.id : spec.id]=rawValue}
                    settings[selectedSceneID]=scene
                    receivedContinuous.append(spec.id)
                }
            }
            refreshParameters(delta:0)
            sendContinuousInputTriggers(receivedContinuous)
        }
        // Iterate messages, not changed values: repeated high cues must restart again.
        for route in globalOSC where route.address == address && route.isValid {
            guard values.indices.contains(route.argument), let value = OSCValue.normalized(values[route.argument]) else { continue }
            if globalThresholdRoutes[route.id] != route { globalThresholds.removeValue(forKey:route.id);globalThresholdRoutes[route.id]=route }
            let fires: Bool
            if route.enabled && route.triggerMode == .threshold {
                fires=globalThresholds[route.id,default:ThresholdLatch()].accept(value,settings:route.threshold ?? .init())
            } else { fires=route.accepts(address:address,values:values) }
            let count = globalReceipts[route.id]?.triggerCount ?? 0
            globalReceipts[route.id] = OSCReceipt(value:value,receivedAt:receivedAt,triggerCount:count+(fires ? 1 : 0),
                packetCount:(globalReceipts[route.id]?.packetCount ?? 0)+1)
            if fires { performGlobalAction(route) }
        }
    }
    func performGlobalAction(_ route: GlobalOSCMapping) {
        switch route.action {
        case .scene:
            guard let id = route.sceneID, scenes.contains(where: { $0.id == id }) else { return }
            selectedSceneID = id; playing = true
        case .next, .previous:
            let sequence = scenes.filter { !$0.testScene }
            guard !sequence.isEmpty else { return }
            let index = sequence.firstIndex { $0.id == selectedSceneID } ?? (route.action == .next ? -1 : 0)
            selectedSceneID = sequence[(index+(route.action == .next ? 1 : -1)+sequence.count)%sequence.count].id
            playing = true
        case .restart: textureSource?.reset(); restartPlayback(); playing = true
        case .play: playing = true
        case .pause: playing = false
        }
    }

    func registerPreview(mode: Float, size: CGSize) {
        let width=Int(size.width),height=Int(size.height)
        guard width > 0, height > 0 else { return }
        if let current=previewSurfaces[mode],current.width==width,current.height==height { return }
        previewSurfaces[mode] = BenchmarkSurface(name:mode == 1 ? "링" : (mode == 0 ? "펼친 영상" : "출력 미리보기"),
                                                width:width,height:height,mode:mode)
    }
    func startBenchmark(resolution: OutputResolution, includePreviews: Bool) {
        guard !updateInstallationInProgress else { return }
        guard !performance.isRunning, !outputOpen, !usesTexture, let scene=selectedScene,
              let device=OrbitGPU.shared.device else { return }
        do {
            let size=resolution.size(availablePixels:.zero,customWidth:3840)
            var surfaces=[BenchmarkSurface(name:"출력",width:Int(size.width),height:Int(size.height),mode:2)]
            if includePreviews { surfaces += previewSurfaces.sorted {$0.key<$1.key}.map(\.value) }
            let request=BenchmarkRequest(sceneName:scene.name,device:device,pipeline:try OrbitGPU.shared.pipeline(for:scene),
                surfaces:surfaces,uniforms:uniforms(width:Float(size.width),height:Float(size.height),view:2),
                speed:playing ? playbackSpeed : 0)
            comparison.stop()
            performance.start(request) { [weak self] in
                guard let self else { return }
                self.lastTime=CACurrentMediaTime(); self.previewRate.reset()
                self.telemetry.updateFPS(preview:nil,output:nil)
            }
        } catch { performance.failed(error.localizedDescription) }
    }

    func uniforms(width: Float, height: Float, view: Float) -> [Float] {
        // A shared monotonic clock for every preview and output. Rendering delays must not slow time.
        let now = CACurrentMediaTime(); let delta = max(0, now - lastTime); lastTime = now
        var values = SceneTrigger.renderValues(base:parameterValues,events:sceneTriggers,levels:triggerLevels(),specs:parameterSpecs).mapValues(Float.init)
        for parameter in allShaderParameters { values[parameter.uniform] = values[parameter.id] ?? Float(parameter.defaultValue) }
        let speed = values["speed"] ?? playbackSpeed
        if playing { phaseTime += delta * Double(speed) }
        if usesTexture, let scene = selectedScene, let original = scene.texture {
            let texture = original
            if let url = resources.url(forResource: texture.file, withExtension: nil, subdirectory: "textures") {
                textureSource?.request(sceneID:scene.id,descriptor:texture,url:url,seconds:phaseTime)
            } else if textureStatus != "텍스처 파일 없음" {
                DispatchQueue.main.async { self.textureStatus = "텍스처 파일 없음"; self.errorMessage = "앱에 추출 텍스처가 포함되지 않았습니다." }
            }
        }
        if showReference && previewsEnabled, let scene = selectedScene, scene.referenceImage == nil,
           let range = scene.referenceSeconds, range.count == 2 {
            let duration = max(1, range[1] - range[0] - 2)
            comparison.sync(scene: scene, seconds: phaseTime.truncatingRemainder(dividingBy:duration), playing: playing, speed: speed)
        }
        let names = ["density","turbulence","energy","hueShift","brightness","seed","angleOffset","flipU","flipV","ringWidth","testPattern","markerWidth",
                     "coverage","gapSoftness","gapMotion","fragmentation","shape0","shape1","shape2","shape3"]
        // Existing scenes retain the stable 96-byte layout. Pulse Orbit appends its shared particle state.
        var packed = [width,height,view,Float(phaseTime)] + names.map { values[$0] ?? 0 }
        if selectedSceneID == PulseOrbitSimulation.sceneID {
            packed += pulseOrbit.uniforms
            // These are authored motion rules, not hidden legacy controls.
            packed += [0,1,0,Float(pulseOrbit.time)]+PulseOrbitSimulation.motionUniforms
            packed += PulseOrbitSimulation.interactionUniforms
            packed += pulseOrbit.eventUniforms
            packed += pulseOrbit.extendedUniforms
            packed += pulseOrbit.accentUniforms
            packed += pulseOrbit.traceUniforms
            if playing {
                pulseOrbit.advance(by: delta * Double(speed), controls: .init(uniforms: packed))
                deliverPulseCrossings()
            }
            pulseOrbit.writeState(to: &packed)
        }
        return packed
    }
    func frameRendered(output: Bool, outputSession: UUID? = nil, at time: CFTimeInterval) {
        if output {
            guard let controller=outputController, controller.sessionID == outputSession else { return }
            outputRate.record(completedAt:time)
        } else {
            previewRate.record(completedAt:time)
        }
    }
    func framePresented(output: Bool, outputSession: UUID? = nil, at time: CFTimeInterval) {
        guard time.isFinite, time > 0 else { return }
        if output && outputController?.sessionID != outputSession { return }
        if output && outputController == nil { return }
        // Report the rendered content clock, not a separate wall-clock animation.
        // Pausing or speed zero holds this value along with the shader image.
        telemetry.updateTime(phaseTime)
        if output {
            outputPresentationTime = max(outputPresentationTime,time)
            if outputController != nil && !outputActive { outputActive = true; outputStatus = "LIVE · \(outputName)" }
        }
    }
    func refreshDisplays() {
        guard !isShuttingDown else { return }
        refreshingDisplays = true
        defer { refreshingDisplays = false }
        displays = NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = n.uint32Value
            return OutputDisplay(id: id, name: screen.localizedName,
              pixels: "\(CGDisplayPixelsWide(id)) × \(CGDisplayPixelsHigh(id))", isMain: screen == NSScreen.main,
              uuid: CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil,$0.takeRetainedValue()) as String } ?? "display-\(id)")
        }
        let missing = selectedDisplayID != 0 && !displays.contains { $0.id == selectedDisplayID }
        let reopen = missing && outputOpen
        let wasFullscreen = outputFullscreen
        selectedDisplayID = displays.first { $0.uuid == preferredDisplayUUID }?.id ?? 0
        displayFallback = preferredDisplayUUID != nil && selectedDisplayID == 0
        if reopen {
            startOutput()
            if wasFullscreen { DispatchQueue.main.async { [weak self] in self?.toggleOutputFullscreen() } }
        }
    }
    func startOutput() {
        guard !isShuttingDown, !performance.isRunning, !updateInstallationInProgress else { return }
        stopOutput()
        let currentScreen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        let screen = (selectedDisplayID == 0 ? currentScreen : NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == selectedDisplayID
        })) ?? currentScreen ?? NSScreen.screens.first
        guard let screen else { errorMessage = "출력할 화면을 찾을 수 없습니다."; return }
        let controller = OrbitOutputWindowController(model: self, screen: screen,
                            resolution: outputResolution, customWidth: customOutputWidth)
        let session = controller.sessionID
        outputController = controller
        outputOpen = true; outputFullscreen = false
        outputScreenName = screen.localizedName
        outputStatus = "출력 프레임 대기"; outputPresentationTime = CACurrentMediaTime()
        controller.closed = { [weak self] in
            guard self?.outputController?.sessionID == session else { return }
            self?.outputController = nil; self?.clearOutputState()
        }
        controller.changed = { [weak self] fullscreen,name,size in
            // Geometry callbacks originate in AppKit layout. Publish after that layout finishes.
            DispatchQueue.main.async {
                guard let self, self.outputController?.sessionID == session else { return }
                if self.outputFullscreen != fullscreen { self.outputFullscreen = fullscreen }
                if !self.previewsEnabled { self.comparison.stop(); self.previewSurfaces.removeAll(); self.previewRate.reset() }
                if self.outputScreenName != name { self.outputScreenName = name }
                if self.outputRenderSize != size { self.outputRenderSize = size }
                if self.outputActive { self.outputStatus = "LIVE · \(name)" }
                self.scheduleSave()
            }
        }
        controller.open(); scheduleSave()
    }
    func toggleOutputFullscreen() { if !isShuttingDown { outputController?.toggleFullscreen() } }
    func stopOutput() {
        let controller = outputController; outputController = nil
        controller?.shutdown(); clearOutputState()
    }
    private func clearOutputState() {
        outputRate.reset(); telemetry.resetOutput(); outputPresentationTime = 0
        outputActive = false; outputOpen = false; outputFullscreen = false
        outputRenderSize = .zero; outputScreenName = ""; outputStatus = "출력 꺼짐"
        scheduleSave()
    }
    deinit {
        controlTimer?.invalidate(); heartbeat?.invalidate()
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
    }
}
