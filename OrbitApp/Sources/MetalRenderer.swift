import SwiftUI
import MetalKit

final class OrbitGPU {
    static let shared = OrbitGPU()
    let device = MTLCreateSystemDefaultDevice()
    lazy var queue = device?.makeCommandQueue()
    private var pipelines: [String: MTLRenderPipelineState] = [:]

    func pipeline(for scene: SceneDescriptor, textured: Bool = false) throws -> MTLRenderPipelineState {
        let key = textured ? "OrbitTexture" : scene.id
        if let cached = pipelines[key] { return cached }
        guard let device,
              let shaderURL = Bundle.main.url(forResource: key, withExtension: "metal", subdirectory: "metal"),
              let vertexURL = Bundle.main.url(forResource: "OrbitFullscreen", withExtension: "metal", subdirectory: "metal") else {
            throw NSError(domain: "Orbit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Metal 장치 또는 셰이더 파일을 찾을 수 없습니다."])
        }
        let source = try String(contentsOf: vertexURL) + "\n" + String(contentsOf: shaderURL)
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: source, options: options)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "orbit_fullscreen_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: textured ? "orbit_texture_fragment" : scene.fragmentFunction)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[key] = pipeline
        return pipeline
    }
}

final class OrbitMTKView: MTKView {
    var renderer: OrbitRenderer?
}

struct OrbitMetalView: NSViewRepresentable {
    let model: OrbitModel
    let mode: Float
    static func make(model: OrbitModel, mode: Float, isOutput: Bool = false, outputSession: UUID? = nil) -> OrbitMTKView {
        let view = OrbitMTKView(frame: .zero, device: OrbitGPU.shared.device)
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = model.frameRate.target(screenMaximum:NSScreen.main?.maximumFramesPerSecond ?? 60)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        let renderer = OrbitRenderer(model: model, mode: mode, isOutput: isOutput, outputSession: outputSession)
        view.renderer = renderer
        view.delegate = renderer
        return view
    }
    func makeNSView(context: Context) -> OrbitMTKView { Self.make(model: model, mode: mode) }
    func updateNSView(_ view: OrbitMTKView, context: Context) {}
    static func dismantleNSView(_ view: OrbitMTKView, coordinator: ()) {
        view.isPaused = true; view.delegate = nil; view.renderer = nil
    }
}

final class OrbitRenderer: NSObject, MTKViewDelegate {
    private weak var model: OrbitModel?
    private let mode: Float
    private let isOutput: Bool
    private let outputSession: UUID?
    private var failedScene: String?
    init(model: OrbitModel, mode: Float, isOutput: Bool, outputSession: UUID? = nil) {
        self.model = model; self.mode = mode; self.isOutput = isOutput; self.outputSession = outputSession
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let model, !model.performance.isRunning else { return }
        let target=model.frameRate.target(screenMaximum:view.window?.screen?.maximumFramesPerSecond ?? 60)
        if view.preferredFramesPerSecond != target { view.preferredFramesPerSecond = target }
        if !isOutput { model.registerPreview(mode:mode,size:view.drawableSize) }
        guard view.drawableSize.width > 0, view.drawableSize.height > 0,
              let scene = model.selectedScene, failedScene != scene.id,
              let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = OrbitGPU.shared.queue?.makeCommandBuffer() else { return }
        do {
            let uniforms = model.uniforms(width: Float(view.drawableSize.width), height: Float(view.drawableSize.height), view: mode)
            let pipeline = try OrbitGPU.shared.pipeline(for: scene, textured:model.usesTexture)
            let textureFrame = model.usesTexture ? model.textureSource?.snapshot() : nil
            guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.setRenderPipelineState(pipeline)
            uniforms.withUnsafeBytes { bytes in
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }
            if model.usesTexture {
                if let frame = textureFrame, frame.sceneID == scene.id {
                    encoder.setFragmentTexture(frame.texture,index:0)
                    encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
                    command.addCompletedHandler { _ in withExtendedLifetime(frame) {} }
                }
            } else {
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            encoder.endEncoding()
            if isOutput || mode == 1 {
                let output = isOutput; let session = outputSession
                command.addCompletedHandler { [weak model] completed in
                    guard completed.status == .completed else { return }
                    let time = completed.gpuEndTime > 0 ? completed.gpuEndTime : CACurrentMediaTime()
                    DispatchQueue.main.async { model?.frameRendered(output:output,outputSession:session,at:time) }
                }
                drawable.addPresentedHandler { [weak model] _ in
                    // Some window/compositor configurations return a zero presentedTime.
                    // Keep presentation liveness independent of the GPU completion meter.
                    let time = CACurrentMediaTime()
                    DispatchQueue.main.async { model?.framePresented(output: output, outputSession: session, at:time) }
                }
            }
            command.present(drawable)
            command.commit()
        } catch {
            failedScene = scene.id
            DispatchQueue.main.async { [weak model] in model?.errorMessage = error.localizedDescription }
        }
    }
}
