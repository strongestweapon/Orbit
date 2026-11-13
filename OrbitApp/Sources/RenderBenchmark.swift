import Foundation
import Metal
import QuartzCore

struct BenchmarkSurface {
    let name: String
    let width: Int
    let height: Int
    let mode: Float
}

struct BenchmarkRequest {
    let sceneName: String
    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let surfaces: [BenchmarkSurface]
    let uniforms: [Float]
    let speed: Float
    var warmupSeconds: Double = 1
    var durationSeconds: Double = 5
}

struct BenchmarkResult {
    let sceneName: String
    let deviceName: String
    let surfaces: [BenchmarkSurface]
    let frames: Int
    let elapsedSeconds: Double
    let gpuMedianMS: Double?
    let gpuP95MS: Double?
    var framesPerSecond: Double { Double(frames)/elapsedSeconds }
}

final class BenchmarkCancellation {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

enum BenchmarkError: LocalizedError {
    case cancelled, failed(String)
    var errorDescription: String? {
        switch self {
        case .cancelled: return "측정을 중지했습니다."
        case .failed(let message): return message
        }
    }
}

/// Offscreen throughput: no MTKView timer, display link, present call, or vsync.
/// Three independent target sets keep up to three frames in flight, just as a
/// pipelined renderer would. FPS counts completed frames over elapsed wall time;
/// it is not the reciprocal of a single GPU duration.
enum RenderBenchmark {
    static func run(_ request: BenchmarkRequest, cancellation: BenchmarkCancellation,
                    progress: (Double)->Void = { _ in }) throws -> BenchmarkResult {
        guard request.uniforms.count == 24, !request.surfaces.isEmpty,
              request.durationSeconds.isFinite, request.durationSeconds > 0,
              request.warmupSeconds.isFinite, request.warmupSeconds >= 0,
              request.surfaces.allSatisfy({ $0.width > 0 && $0.height > 0 }),
              let queue = request.device.makeCommandQueue() else {
            throw BenchmarkError.failed("GPU 측정 구성을 만들 수 없습니다.")
        }
        let targets = try (0..<3).map { _ in
            try request.surfaces.map { surface -> MTLTexture in
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,
                    width:surface.width,height:surface.height,mipmapped:false)
                descriptor.storageMode = .private; descriptor.usage = .renderTarget
                guard let texture = request.device.makeTexture(descriptor:descriptor) else {
                    throw BenchmarkError.failed("측정용 영상 메모리를 만들 수 없습니다.")
                }
                return texture
            }
        }
        let phaseStart = CACurrentMediaTime()
        func stage(seconds: Double, measured: Bool) throws -> (Int,Double,[Double]) {
            var pending = [MTLCommandBuffer?](repeating:nil,count:3)
            defer { for command in pending { command?.waitUntilCompleted() } }
            var submitted = 0, completed = 0
            var gpuMS: [Double] = []
            let start = CACurrentMediaTime()
            var lastProgress = start
            func collect(_ index: Int) throws {
                guard let command = pending[index] else { return }
                command.waitUntilCompleted(); pending[index] = nil
                guard command.status == .completed else {
                    throw BenchmarkError.failed(command.error?.localizedDescription ?? "GPU 측정 중 오류가 발생했습니다.")
                }
                completed += 1
                if measured, command.gpuEndTime > command.gpuStartTime, command.gpuStartTime > 0 {
                    gpuMS.append((command.gpuEndTime-command.gpuStartTime)*1000)
                }
            }
            while CACurrentMediaTime()-start < seconds {
                if cancellation.isCancelled { throw BenchmarkError.cancelled }
                try autoreleasepool {
                    let slot = submitted%3
                    try collect(slot)
                    guard let command = queue.makeCommandBuffer() else {
                        throw BenchmarkError.failed("GPU 작업을 만들 수 없습니다.")
                    }
                    let phase = request.uniforms[3] + Float(CACurrentMediaTime()-phaseStart)*request.speed
                    for (index,surface) in request.surfaces.enumerated() {
                        let pass = MTLRenderPassDescriptor()
                        pass.colorAttachments[0].texture = targets[slot][index]
                        pass.colorAttachments[0].loadAction = .clear
                        pass.colorAttachments[0].storeAction = .store
                        pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1)
                        guard let encoder = command.makeRenderCommandEncoder(descriptor:pass) else {
                            throw BenchmarkError.failed("GPU 렌더 작업을 만들 수 없습니다.")
                        }
                        var uniforms = request.uniforms
                        uniforms[0] = Float(surface.width); uniforms[1] = Float(surface.height)
                        uniforms[2] = surface.mode; uniforms[3] = phase
                        encoder.setRenderPipelineState(request.pipeline)
                        uniforms.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!,length:$0.count,index:0) }
                        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
                        encoder.endEncoding()
                    }
                    command.commit(); pending[slot] = command; submitted += 1
                }
                let now = CACurrentMediaTime()
                if measured, now-lastProgress >= 0.2 {
                    progress(min(0.99,(now-start)/seconds)); lastProgress = now
                }
            }
            for index in pending.indices { try collect(index) }
            if cancellation.isCancelled { throw BenchmarkError.cancelled }
            return (completed,CACurrentMediaTime()-start,gpuMS)
        }
        _ = try stage(seconds:request.warmupSeconds,measured:false)
        let (frames,elapsed,times) = try stage(seconds:request.durationSeconds,measured:true)
        guard frames > 0, elapsed > 0 else { throw BenchmarkError.failed("완료된 측정 프레임이 없습니다.") }
        let sorted = times.sorted()
        func percentile(_ value:Double)->Double? {
            sorted.isEmpty ? nil : sorted[min(sorted.count-1,Int(Double(sorted.count-1)*value))]
        }
        progress(1)
        return BenchmarkResult(sceneName:request.sceneName,deviceName:request.device.name,
            surfaces:request.surfaces,frames:frames,elapsedSeconds:elapsed,
            gpuMedianMS:percentile(0.5),gpuP95MS:percentile(0.95))
    }
}
