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
    @Published var sensors = [
        SensorInput(name: "레이싱 속도", address: "/park/racing/speed"),
        SensorInput(name: "관람객 수", address: "/park/visitors")
    ]
    @Published var port = "9000" { didSet { scheduleSave() } }
    @Published var oscState = "수신 꺼짐"
    @Published var oscRunning = false
    @Published var lastMessage = "OSC 데이터 대기"
    @Published var playing = true { didSet { lastTime = CACurrentMediaTime(); scheduleSave() } }
    @Published var frameRate: PlaybackFrameRate = .sixty { didSet { scheduleSave() } }
    @Published var previewPolicy: PreviewPolicy = .always {
        didSet { if !previewsEnabled { comparison.stop(); previewSurfaces.removeAll(); previewRate.reset() }; scheduleSave() }
    }
    @Published var resumeOnLaunch = true { didSet { scheduleSave() } }
    @Published var globalOSC: [GlobalOSCMapping] = [] { didSet { scheduleSave() } }
    @Published private(set) var globalReceipts: [UUID:OSCReceipt] = [:]
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
    @Published var controlOutputEnabled = false {
        didSet {
            if updateInstallationInProgress && controlOutputEnabled { controlOutputEnabled = false }
            controlOutput.reset(); controlOutputStatus = controlOutputEnabled ? "제어 송신 대기" : "제어 자동 송신 꺼짐"
            scheduleSave()
        }
    }
    var updateInstallationInProgress = false
    @Published var controlOutputStatus = "제어 자동 송신 꺼짐"
    @Published private(set) var controlDeliveries: [String:ControlDelivery] = [:]
    let receiver = OSCReceiver()
    let telemetry = PlaybackTelemetry()
    let performance = PerformanceMeasurement()
    private var previewSurfaces: [Float:BenchmarkSurface] = [:]
    let controlOutput = ControlOutput()
    let comparison = ComparisonPlayback()
    let textureSource = OrbitGPU.shared.device.map { OrbitTextureSource(device:$0) }
    private var phaseTime: Double = 0
    private var lastTime = CACurrentMediaTime()
    private var parameterResolver = ParameterResolver()
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
        (usesTexture ? activeSettings.textureParameterRoutes : activeSettings.parameterRoutes) ?? [:]
    }
    var shaderParameters: [ShaderParameter] { usesTexture ? [] : (selectedScene?.parameters ?? []) }
    var allShaderParameters: [ShaderParameter] { usesTexture ? [] : (selectedScene?.allParameters ?? []) }
    var connectedCompatibilityParameters: [ShaderParameter] {
        (selectedScene?.compatibilityParameters ?? []).filter {
            let route = activeRoutes[$0.id]
            return route?.input.enabled == true || route?.output.enabled == true
        }
    }
    var parameterSpecs: [ParameterSpec] {
        if usesTexture || selectedScene?.testScene == true { return ParameterSpec.all }
        let common = ParameterSpec.all.filter { !["density","turbulence","energy","rotation"].contains($0.id) }
        return common + allShaderParameters.enumerated().map { $0.element.spec(index:$0.offset) }
    }
    func parameterSpec(_ key: String) -> ParameterSpec { parameterSpecs.first { $0.id == key } ?? .find(key) }
    var manualPlaybackSpeed: Float { usesTexture ? (activeSettings.values["texture.speed"] ?? 1) : activeSettings.speed }
    var playbackSpeed: Float { Float(parameterValues["speed"] ?? Double(manualPlaybackSpeed)) }
    var activeControlOutputCount: Int { activeRoutes.values.filter { $0.output.enabled }.count }
    var outputParameterSpecs: [ParameterSpec] {
        guard selectedScene?.testScene == false else { return [] }
        return parameterSpecs.filter { spec in
            guard let route = activeRoutes[spec.id]?.output else { return false }
            return route.isListed(defaultRoute:ParameterRoute.defaults(scene:selectedSceneID,parameter:spec.id,spec:spec).output)
        }
    }
    func controlEmissionID(_ key: String) -> String { "\(selectedSceneID):\(renderStyle):\(key)" }
    func controlDelivery(for key: String) -> ControlDelivery? {
        guard let delivery = controlDeliveries[controlEmissionID(key)],
              delivery.destination == route(for:key).output.destinationKey else { return nil }
        return delivery
    }
    func clearControlOutput(_ key: String) {
        let original = ParameterRoute.defaults(scene:selectedSceneID,parameter:key,spec:parameterSpec(key)).output
        controlDeliveries.removeValue(forKey:controlEmissionID(key))
        setRoute(key) { $0.output = original }
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

    init(defaults: UserDefaults = .standard, resources: Bundle = .main) {
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
                globalOSC = stored.globalOSC ?? globalOSC
                startupSession = stored.installation
                preferredDisplayUUID = stored.installation?.displayUUID
                if let id = stored.installation?.selectedSceneID, scenes.contains(where: { $0.id == id }) { selectedSceneID = id }
                if let rate = stored.installation?.frameRate { frameRate = PlaybackFrameRate(rawValue:rate) ?? .sixty }
                previewPolicy = stored.installation?.previewPolicy ?? .always
                playing = stored.installation?.playing ?? true
                resumeOnLaunch = stored.installation?.resumeOnLaunch ?? true
            }
        } catch { errorMessage = error.localizedDescription }
        for key in Array(settings.keys) { settings[key]?.migrateRoutes(scene:key) }
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
            DispatchQueue.main.async { self?.controlDeliveries[delivery.id] = delivery }
        }
        controlOutput.prepare()
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
        let data = try? JSONEncoder().encode(StoredSettings(sensors: persistedSensors, scenes: settings, port: port, motionRevision: 2, rendererRevision: 3, outputResolution: outputResolution, customOutputWidth: customOutputWidth, installation:installation, globalOSC:globalOSC))
        if let data { defaults.set(data, forKey: "OrbitSettings.v1") }
    }
    func restoreSessionOnce() {
        guard !sessionRestored, !isShuttingDown else { return }; sessionRestored = true
        guard resumeOnLaunch, let session = startupSession else { return }
        startupSession = nil
        if session.oscReceiving == true { startOSC() }
        controlOutputEnabled = session.controlSending ?? false
        if session.outputOpen == true {
            startOutput()
            if session.outputFullscreen == true {
                DispatchQueue.main.async { [weak self] in self?.toggleOutputFullscreen() }
            }
        }
    }
    func value(_ name: String) -> Float { Float(parameterValues[name] ?? Double(effectiveValues[name] ?? 0)) }
    func baseParameterValue(_ key: String) -> Double { key == "speed" ? Double(manualPlaybackSpeed) : Double(effectiveValues[key] ?? 0) }
    func normalizedParameterValue(_ key: String) -> Double {
        parameterSpec(key).normalized(parameterValues[key] ?? baseParameterValue(key))
    }
    func setNormalizedParameterValue(_ key: String, _ value: Double) {
        let raw = Float(parameterSpec(key).rawValue(normalized:value))
        if key == "speed" { setSpeed(raw) } else { setValue(key,raw) }
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
        guard value.isFinite else { return }
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
        phaseTime = 0; lastTime = CACurrentMediaTime()
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
        activeRoutes[key] ?? ParameterRoute.defaults(scene:selectedSceneID,parameter:key,spec:parameterSpec(key))
    }
    func setRoute(_ key: String, _ update: (inout ParameterRoute) -> Void) {
        var route = route(for:key); let prior = route; update(&route)
        let spec = parameterSpec(key)
        route.input.minimum = spec.clamp(route.input.minimum)
        route.input.maximum = spec.clamp(route.input.maximum)
        route.input.smoothingSeconds = route.input.smoothingSeconds.isFinite ? min(30,max(0,route.input.smoothingSeconds)) : 8
        if !route.output.minimum.isFinite { route.output.minimum = prior.output.minimum }
        if !route.output.maximum.isFinite { route.output.maximum = prior.output.maximum }
        var scene = activeSettings; var routes = activeRoutes; routes[key] = route
        if usesTexture { scene.textureParameterRoutes = routes } else { scene.parameterRoutes = routes }
        settings[selectedSceneID] = scene
        refreshParameters(delta:0)
    }
    func outputIssue(for key: String) -> String? {
        let route = route(for:key).output
        if let issue = route.validationError { return issue }
        if let other = activeRoutes.first(where: { $0.key != key && $0.value.output.enabled && $0.value.output.destinationKey == route.destinationKey }) {
            return "\(parameterSpec(other.key).title)와 출력 주소가 겹칩니다. 채널·CC 또는 OSC 주소를 바꾸세요."
        }
        return nil
    }
    func testControlOutput(_ key: String) {
        guard let spec = parameterSpecs.first(where: { $0.id == key }), outputIssue(for:key) == nil else { return }
        // Isolate this parameter during Live's MIDI learn, even if other routes were transmitting.
        controlOutputEnabled = false
        setRoute(key) { $0.output.configured = true }
        let route = route(for:key).output
        if let value = route.mappedValue(parameterValues[key] ?? baseParameterValue(key),spec:spec) {
            controlOutput.send([ControlEmission(id:controlEmissionID(key),route:route,value:value)],force:true)
        }
    }
    private func resetParameterState() {
        parameterResolver.reset(); controlOutput.reset(); lastControlTime = CACurrentMediaTime()
        refreshParameters(delta:0)
    }
    private func refreshParameters(delta: Double) {
        var base = effectiveValues.mapValues(Double.init); base["speed"] = Double(manualPlaybackSpeed)
        let routes = selectedScene?.testScene == false ? activeRoutes : [:]
        var resolved = parameterResolver.resolve(base:base,routes:routes,sensors:sensors,now:Date(),delta:delta,specs:parameterSpecs)
        if usesTexture { resolved["markerWidth"] = (resolved["rotation"] ?? 0)*0.1 }
        if parameterValues != resolved { parameterValues = resolved }
        guard controlOutputEnabled else { return }
        let emissions = parameterSpecs.compactMap { spec -> ControlEmission? in
            guard let route = routes[spec.id]?.output, route.enabled, outputIssue(for:spec.id) == nil,
                  let value = route.mappedValue(resolved[spec.id] ?? baseParameterValue(spec.id),spec:spec) else { return nil }
            return ControlEmission(id:controlEmissionID(spec.id),route:route,value:value)
        }
        controlOutput.send(emissions)
    }
    func addSensor() {
        sensors.append(SensorInput(name: "센서 \(sensors.count + 1)", address: "/park/sensor/\(sensors.count + 1)"))
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
    func stopOSC() { oscSessionID=UUID();receiver.stop(); oscRunning = false; oscState = "수신 꺼짐"; scheduleSave() }

    func receiveOSC(address: String, values: [Double]) {
        guard !isShuttingDown else { return }
        lastMessage = address + "  " + values.map { OSCValue.normalized($0).map { String(format:"%.2f",$0) } ?? "실수 필요" }.joined(separator:", ")
        for i in sensors.indices where sensors[i].address == address {
            let argument = sensors[i].argument
            if values.indices.contains(argument), let value = OSCValue.normalized(values[argument]) {
                sensors[i].value = value; sensors[i].receivedAt = Date()
            }
        }
        // Iterate messages, not changed values: repeated high cues must restart again.
        for route in globalOSC where route.address == address && route.isValid {
            guard values.indices.contains(route.argument), let value = OSCValue.normalized(values[route.argument]) else { continue }
            let fires = route.accepts(address:address,values:values)
            let count = globalReceipts[route.id]?.triggerCount ?? 0
            globalReceipts[route.id] = OSCReceipt(value:value,receivedAt:Date(),triggerCount:count+(fires ? 1 : 0))
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
        var values = parameterValues.mapValues(Float.init)
        for parameter in allShaderParameters { values[parameter.uniform] = values[parameter.id] ?? Float(parameter.defaultValue) }
        let speed = playbackSpeed
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
        // Stable 96-byte GPU layout; semantic parameter IDs are packed into their declared slots.
        return [width,height,view,Float(phaseTime)] + names.map { values[$0] ?? 0 }
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
