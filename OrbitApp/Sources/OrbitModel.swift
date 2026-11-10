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
}
struct SceneManifest: Decodable { let scenes: [SceneDescriptor] }

struct SensorInput: Identifiable, Codable {
    var id = UUID()
    var name: String
    var address: String
    var argument = 0
    var minimum: Double = 0
    var maximum: Double = 100
    var value: Double?
    var receivedAt: Date?
}
struct SensorMapping: Codable, Equatable {
    var sensorID: UUID?
    var target = "energy"
    var minimum: Double = 0.25
    var maximum: Double = 0.9
    var smoothingSeconds: Double = 8
    var enabled = false
}
struct SceneSettings: Codable {
    var values: [String: Float]
    var speed: Float
    var mapping = SensorMapping()
    var useTexture: Bool?
    var textureMapping: SensorMapping?
}
struct StoredSettings: Codable {
    var sensors: [SensorInput]
    var scenes: [String: SceneSettings]
    var port: String
    var motionRevision: Int?
    var rendererRevision: Int?
    var outputResolution: OutputResolution?
    var customOutputWidth: Int?
}
struct OutputDisplay: Identifiable {
    let id: UInt32
    let name: String
    let pixels: String
    let isMain: Bool
}

final class OrbitModel: ObservableObject {
    @Published var scenes: [SceneDescriptor] = []
    @Published var selectedSceneID = "07_spectral_fragments" {
        didSet { comparison.stop(); textureSource?.reset(); textureStatus = "텍스처 준비 중"; restartPlayback(); smoothedValues.removeAll() }
    }
    @Published var settings: [String: SceneSettings] = [:]
    @Published var sensors = [
        SensorInput(name: "레이싱 속도", address: "/park/racing/speed"),
        SensorInput(name: "관람객 수", address: "/park/visitors", maximum: 500)
    ]
    @Published var port = "9000"
    @Published var oscState = "수신 꺼짐"
    @Published var oscRunning = false
    @Published var lastMessage = "OSC 데이터 대기"
    @Published var playing = true { didSet { lastTime = CACurrentMediaTime() } }
    @Published private(set) var playbackSeconds: Double = 0
    @Published var showReference = false {
        didSet { if showReference { restartPlayback() } else { comparison.stop() } }
    }
    @Published var errorMessage: String?
    @Published var displays: [OutputDisplay] = []
    @Published var selectedDisplayID: UInt32 = 0
    @Published var outputActive = false
    @Published private(set) var outputOpen = false
    @Published private(set) var outputFullscreen = false
    @Published private(set) var outputRenderSize: CGSize = .zero
    @Published private(set) var outputScreenName = ""
    @Published var outputResolution: OutputResolution = .automatic
    @Published var customOutputWidth: Int = 1920
    @Published var outputStatus = "출력 꺼짐"
    @Published var fps: Double = 0
    @Published var textureStatus = "텍스처 준비 중"
    let receiver = OSCReceiver()
    let comparison = ComparisonPlayback()
    let textureSource = OrbitGPU.shared.device.map { OrbitTextureSource(device:$0) }
    private var phaseTime: Double = 0
    private var lastTime = CACurrentMediaTime()
    private var smoothedValues: [String: Float] = [:]
    private var outputController: OrbitOutputWindowController?
    private var outputPresentationTime: CFTimeInterval = 0
    private var frameCount = 0
    private var fpsTime = CACurrentMediaTime()
    private var displayObserver: NSObjectProtocol?
    private var heartbeat: Timer?
    private var saves = Set<AnyCancellable>()

    var selectedScene: SceneDescriptor? { scenes.first { $0.id == selectedSceneID } }
    var activeSettings: SceneSettings {
        settings[selectedSceneID] ?? SceneSettings(values: [:], speed: 1)
    }
    var usesTexture: Bool { selectedScene?.texture != nil && (activeSettings.useTexture ?? false) }
    var renderStyle: Int { usesTexture ? 1 : 0 }
    var mapping: SensorMapping { usesTexture ? (activeSettings.textureMapping ?? SensorMapping()) : activeSettings.mapping }
    var playbackSpeed: Float { usesTexture ? (activeSettings.values["texture.speed"] ?? 1) : activeSettings.speed }
    var playbackTimeLabel: String {
        let tenths = Int(max(0,playbackSeconds)*10)
        return String(format:"%02d:%02d.%d",tenths/600,(tenths/10)%60,tenths%10)
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

    init() {
        do {
            guard let url = Bundle.main.url(forResource: "scenes", withExtension: "json", subdirectory: "config") else {
                throw NSError(domain: "Orbit", code: 1, userInfo: [NSLocalizedDescriptionKey: "씬 목록이 앱에 포함되지 않았습니다."])
            }
            let manifest = try JSONDecoder().decode(SceneManifest.self, from: Data(contentsOf: url))
            scenes = manifest.scenes.filter { !$0.testScene } + manifest.scenes.filter { $0.testScene }
            for scene in scenes { settings[scene.id] = SceneSettings(values: scene.defaults, speed: scene.defaultClockSpeed) }
            if let data = UserDefaults.standard.data(forKey: "OrbitSettings.v1"),
               let stored = try? JSONDecoder().decode(StoredSettings.self, from: data) {
                sensors = stored.sensors.map { var s = $0; s.receivedAt = nil; return s }
                for (key, value) in stored.scenes where settings[key] != nil {
                    settings[key]?.values.merge(value.values) { _, storedValue in storedValue }
                    settings[key]?.speed = value.speed
                    settings[key]?.mapping = value.mapping
                    settings[key]?.useTexture = stored.rendererRevision == 3 ? value.useTexture : false
                    settings[key]?.textureMapping = value.textureMapping
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
            }
        } catch { errorMessage = error.localizedDescription }
        textureSource?.onReady = { [weak self] in self?.textureStatus = "텍스처 재생 준비됨" }
        textureSource?.onError = { [weak self] message in
            self?.textureStatus = "텍스처 읽기 실패"; self?.errorMessage = message
        }
        refreshDisplays()
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refreshDisplays() }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if self.outputController != nil && now - self.outputPresentationTime > 1 {
                self.outputActive = false; self.outputStatus = "출력 프레임 대기"
            }
        }
        $settings.dropFirst().debounce(for: .milliseconds(400), scheduler: RunLoop.main).sink { [weak self] _ in self?.save() }.store(in: &saves)
        $sensors.dropFirst().debounce(for: .milliseconds(400), scheduler: RunLoop.main).sink { [weak self] _ in self?.save() }.store(in: &saves)
        $outputResolution.combineLatest($customOutputWidth).dropFirst()
            .sink { [weak self] resolution,width in
                self?.outputController?.configure(resolution: resolution, customWidth: width)
            }.store(in: &saves)
        $outputResolution.combineLatest($customOutputWidth).dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }.store(in: &saves)
        $selectedDisplayID.dropFirst().removeDuplicates().sink { [weak self] _ in self?.stopOutput() }.store(in: &saves)
    }

    func save() {
        let data = try? JSONEncoder().encode(StoredSettings(sensors: sensors, scenes: settings, port: port, motionRevision: 2, rendererRevision: 3, outputResolution: outputResolution, customOutputWidth: customOutputWidth))
        if let data { UserDefaults.standard.set(data, forKey: "OrbitSettings.v1") }
    }
    func value(_ name: String) -> Float { effectiveValues[name] ?? 0 }
    func setValue(_ name: String, _ value: Float) {
        guard value.isFinite else { return }
        let key = usesTexture && textureDefaults[name] != nil ? "texture." + name : name
        settings[selectedSceneID]?.values[key] = value
    }
    func setSpeed(_ speed: Float) {
        if usesTexture { settings[selectedSceneID]?.values["texture.speed"] = speed }
        else { settings[selectedSceneID]?.speed = speed }
    }
    func setTextureMode(_ enabled: Bool) {
        settings[selectedSceneID]?.useTexture = enabled
        textureSource?.reset(); textureStatus = "텍스처 준비 중"
        comparison.stop(); restartPlayback(); smoothedValues.removeAll()
    }
    func setRenderStyle(_ style: Int) {
        setTextureMode(style == 1)
    }
    func restartPlayback() {
        phaseTime = 0; lastTime = CACurrentMediaTime()
        playbackSeconds = 0
        comparison.invalidatePosition()
    }
    func resetSceneAppearance() {
        guard let scene = selectedScene else { return }
        var updated = activeSettings
        if usesTexture {
            for (name, value) in textureDefaults { updated.values["texture." + name] = value }
            updated.values["texture.speed"] = 1
            settings[selectedSceneID] = updated
            restartPlayback(); smoothedValues.removeAll()
            return
        }
        // Keep the installation's orientation and sensor routing intact.
        let appearance = ["density", "turbulence", "energy", "hueShift", "brightness", "seed",
                          "coverage", "gapSoftness", "gapMotion", "fragmentation"]
        for name in appearance { updated.values[name] = scene.defaults[name] }
        updated.speed = scene.defaultClockSpeed
        settings[selectedSceneID] = updated
        restartPlayback(); smoothedValues.removeAll()
    }
    func setMapping(_ update: (inout SensorMapping) -> Void) {
        var m = mapping; update(&m)
        if usesTexture { settings[selectedSceneID]?.textureMapping = m }
        else { settings[selectedSceneID]?.mapping = m }
    }
    func addSensor() {
        sensors.append(SensorInput(name: "센서 \(sensors.count + 1)", address: "/park/sensor/\(sensors.count + 1)"))
    }
    func startOSC() {
        guard let number = UInt16(port), number > 0 else { errorMessage = "UDP 포트는 1–65535 범위여야 합니다."; return }
        receiver.onState = { [weak self] running, message in
            DispatchQueue.main.async { self?.oscRunning = running; self?.oscState = message }
        }
        receiver.onMessage = { [weak self] address, values in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastMessage = address + "  " + values.map { String(format: "%.2f", $0) }.joined(separator: ", ")
                for i in self.sensors.indices where self.sensors[i].address == address {
                    let argument = self.sensors[i].argument
                    if values.indices.contains(argument), values[argument].isFinite {
                        self.sensors[i].value = values[argument]; self.sensors[i].receivedAt = Date()
                    }
                }
            }
        }
        receiver.start(port: number); save()
    }
    func stopOSC() { receiver.stop(); oscRunning = false; oscState = "수신 꺼짐" }

    func uniforms(width: Float, height: Float, view: Float) -> [Float] {
        // A shared monotonic clock for every preview and output. Rendering delays must not slow time.
        let now = CACurrentMediaTime(); let delta = max(0, now - lastTime); lastTime = now
        var values = effectiveValues
        var speed = playbackSpeed
        let m = mapping
        if m.enabled, selectedScene?.testScene == false,
           let sensor = sensors.first(where: { $0.id == m.sensorID }),
           let raw = sensor.value, let received = sensor.receivedAt {
            let base = m.target == "speed" ? playbackSpeed : (values[m.target] ?? 0)
            var target = base
            if Date().timeIntervalSince(received) < 90, sensor.maximum > sensor.minimum {
                let n = max(0, min(1, (raw - sensor.minimum) / (sensor.maximum - sensor.minimum)))
                target = Float(m.minimum + n * (m.maximum - m.minimum))
            }
            let maximum: Float = m.target == "speed" ? 3 : 1
            target = max(0, min(maximum, target))
            let prior = smoothedValues[m.target] ?? base
            let blend = m.smoothingSeconds <= 0 ? 1 : 1 - exp(-delta * 3 / m.smoothingSeconds)
            let smoothed = prior + (target - prior) * Float(blend)
            smoothedValues[m.target] = smoothed
            if m.target == "speed" { speed = smoothed } else { values[m.target] = smoothed }
        }
        if playing { phaseTime += delta * Double(speed) }
        if usesTexture, let scene = selectedScene, let original = scene.texture {
            let texture = original
            if let url = Bundle.main.url(forResource: texture.file, withExtension: nil, subdirectory: "textures") {
                textureSource?.request(sceneID:scene.id,descriptor:texture,url:url,seconds:phaseTime)
            } else if textureStatus != "텍스처 파일 없음" {
                DispatchQueue.main.async { self.textureStatus = "텍스처 파일 없음"; self.errorMessage = "앱에 추출 텍스처가 포함되지 않았습니다." }
            }
        }
        if showReference, let scene = selectedScene, scene.referenceImage == nil,
           let range = scene.referenceSeconds, range.count == 2 {
            let duration = max(1, range[1] - range[0] - 2)
            comparison.sync(scene: scene, seconds: phaseTime.truncatingRemainder(dividingBy:duration), playing: playing, speed: speed)
        }
        let names = ["density","turbulence","energy","hueShift","brightness","seed","angleOffset","flipU","flipV","ringWidth","testPattern","markerWidth",
                     "coverage","gapSoftness","gapMotion","fragmentation"]
        // Pure code generation and optional reference playback share the 80-byte ABI.
        return [width,height,view,Float(phaseTime)] + names.map { values[$0] ?? 0 }
    }
    func framePresented(output: Bool, outputSession: UUID? = nil) {
        if output && outputController?.sessionID != outputSession { return }
        if output && outputController == nil { return }
        // Report the rendered content clock, not a separate wall-clock animation.
        // Pausing or speed zero holds this value along with the shader image.
        if abs(playbackSeconds-phaseTime) >= 0.1 { playbackSeconds = phaseTime }
        if output {
            outputPresentationTime = CACurrentMediaTime()
            if outputController != nil && !outputActive { outputActive = true; outputStatus = "LIVE · \(outputName)" }
        } else {
            frameCount += 1
            let now = CACurrentMediaTime()
            if now - fpsTime > 1 { fps = Double(frameCount) / (now - fpsTime); frameCount = 0; fpsTime = now }
        }
    }
    func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = n.uint32Value
            return OutputDisplay(id: id, name: screen.localizedName,
              pixels: "\(CGDisplayPixelsWide(id)) × \(CGDisplayPixelsHigh(id))", isMain: screen == NSScreen.main)
        }
        if selectedDisplayID != 0 && !displays.contains(where: { $0.id == selectedDisplayID }) {
            stopOutput(); selectedDisplayID = 0; outputStatus = "디스플레이 연결 해제 · 현재 화면 사용 가능"
        }
    }
    func startOutput() {
        stopOutput()
        let currentScreen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        let screen = selectedDisplayID == 0 ? currentScreen : NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == selectedDisplayID
        })
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
                if self.outputScreenName != name { self.outputScreenName = name }
                if self.outputRenderSize != size { self.outputRenderSize = size }
                if self.outputActive { self.outputStatus = "LIVE · \(name)" }
            }
        }
        controller.open()
    }
    func toggleOutputFullscreen() { outputController?.toggleFullscreen() }
    func stopOutput() {
        let controller = outputController; outputController = nil
        controller?.shutdown(); clearOutputState()
    }
    private func clearOutputState() {
        outputActive = false; outputOpen = false; outputFullscreen = false
        outputRenderSize = .zero; outputScreenName = ""; outputStatus = "출력 꺼짐"
    }
}
