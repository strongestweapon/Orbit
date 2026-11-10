import Foundation
@preconcurrency import AVFoundation
import MetalKit
import CoreVideo

struct TextureDescriptor: Decodable {
    let file: String
    let kind: String
    let width: Int
    let height: Int
    let fps: Double
    let frames: Int
    let duration: Double
    let sourceStart: Double
    let sourceEnd: Double
    let seedFile: String?

    var generationSeed: TextureDescriptor {
        TextureDescriptor(file:seedFile ?? file,kind:"image",width:width,height:height,
                          fps:0,frames:1,duration:0,sourceStart:0,sourceEnd:0,seedFile:seedFile)
    }
}

// Keep the CVMetalTexture and its pixel buffer alive until the GPU completes the draw.
struct OrbitTextureFrame {
    let texture: MTLTexture
    let backing: CVMetalTexture?
    let pixelBuffer: CVPixelBuffer?
    let index: Int
    let sceneID: String
}

// Requests and published frames are lock-protected; all decoder state stays on queue.
final class OrbitTextureSource: @unchecked Sendable {
    private let device: MTLDevice
    private let queue = DispatchQueue(label: "studio.superless.Orbit.texture-decode", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var identity: String?
    private var wantedFrame = 0
    private var scheduled = false
    private var failed = false
    private var publishedFrame: OrbitTextureFrame?
    // The following decoder state is accessed only on queue.
    private var asset: AVURLAsset?
    private var track: AVAssetTrack?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var decodedIndex = -1
    private var cache: CVMetalTextureCache?
    var onError: ((String) -> Void)?
    var onReady: (() -> Void)?

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    }
    func snapshot() -> OrbitTextureFrame? {
        lock.lock(); defer { lock.unlock() }
        return publishedFrame
    }
    func reset() {
        lock.lock()
        generation += 1; identity = nil; publishedFrame = nil; scheduled = false; failed = false
        lock.unlock()
        queue.async { self.reader?.cancelReading(); self.reader = nil; self.output = nil; self.asset = nil; self.track = nil }
    }
    private func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == token
    }
    func request(sceneID: String, descriptor: TextureDescriptor, url: URL, seconds: Double) {
        let index = descriptor.kind == "video" ? min(max(0, descriptor.frames - 1),
            Int(floor(max(0, seconds).truncatingRemainder(dividingBy: max(0.01, descriptor.duration)) * descriptor.fps))) : 0
        lock.lock()
        let changed = identity != sceneID
        if changed {
            generation += 1; identity = sceneID; publishedFrame = nil; failed = false; scheduled = true
        }
        wantedFrame = index
        let token = generation
        let enqueue = !changed && !scheduled && !failed && publishedFrame?.index != index
        if enqueue { scheduled = true }
        lock.unlock()
        if changed {
            if descriptor.kind == "image" {
                queue.async {
                    guard self.isCurrent(token) else { return }
                    self.reader?.cancelReading(); self.reader = nil; self.output = nil
                    do {
                        let texture = try MTKTextureLoader(device: self.device).newTexture(URL: url,
                            options: [.SRGB:false, .origin:MTKTextureLoader.Origin.topLeft,
                                      .textureUsage:MTLTextureUsage.shaderRead.rawValue])
                        self.publish(OrbitTextureFrame(texture:texture,backing:nil,pixelBuffer:nil,index:0,sceneID:sceneID), token:token)
                        self.finish(token)
                    } catch { self.report(error, token:token) }
                }
            } else {
                let newAsset = AVURLAsset(url:url)
                Task {
                    do {
                        guard let newTrack = try await newAsset.loadTracks(withMediaType:.video).first else {
                            throw NSError(domain:"OrbitTexture",code:1,userInfo:[NSLocalizedDescriptionKey:"텍스처 영상 트랙이 없습니다."])
                        }
                        self.queue.async {
                            guard self.isCurrent(token) else { return }
                            self.asset = newAsset; self.track = newTrack
                            do { try self.startReader(); self.drain(sceneID:sceneID,token:token) }
                            catch { self.report(error,token:token) }
                        }
                    } catch { self.report(error,token:token) }
                }
            }
        } else if enqueue {
            queue.async { self.drain(sceneID:sceneID,token:token) }
        }
    }
    private func startReader() throws {
        reader?.cancelReading()
        guard let asset, let track else { throw NSError(domain:"OrbitTexture",code:2) }
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String:true,
            kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw NSError(domain:"OrbitTexture",code:3) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain:"OrbitTexture",code:4) }
        self.reader = reader; self.output = output; decodedIndex = -1
    }
    private func drain(sceneID: String, token: Int) {
        do {
            while isCurrent(token) {
                lock.lock(); let target = wantedFrame; lock.unlock()
                if decodedIndex == target { finish(token); return }
                if decodedIndex > target { try startReader() }
                var sample: CMSampleBuffer?
                while decodedIndex < target {
                    guard isCurrent(token) else { return }
                    guard let next = output?.copyNextSampleBuffer() else {
                        throw reader?.error ?? NSError(domain:"OrbitTexture",code:5,
                            userInfo:[NSLocalizedDescriptionKey:"텍스처 프레임을 읽지 못했습니다."])
                    }
                    sample = next; decodedIndex += 1
                }
                guard let sample, let pixels = CMSampleBufferGetImageBuffer(sample), let cache else {
                    throw NSError(domain:"OrbitTexture",code:6)
                }
                var backing: CVMetalTexture?
                let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache,pixels,nil,
                    .bgra8Unorm,CVPixelBufferGetWidth(pixels),CVPixelBufferGetHeight(pixels),0,&backing)
                guard status == kCVReturnSuccess, let backing, let texture = CVMetalTextureGetTexture(backing) else {
                    throw NSError(domain:"OrbitTexture",code:Int(status),userInfo:[NSLocalizedDescriptionKey:"Metal 텍스처 변환에 실패했습니다."])
                }
                publish(OrbitTextureFrame(texture:texture,backing:backing,pixelBuffer:pixels,index:decodedIndex,sceneID:sceneID),token:token)
            }
        } catch { report(error,token:token) }
    }
    private func publish(_ frame: OrbitTextureFrame, token: Int) {
        lock.lock()
        guard generation == token else { lock.unlock(); return }
        let first = publishedFrame == nil; publishedFrame = frame
        lock.unlock()
        if first { DispatchQueue.main.async { if self.isCurrent(token) { self.onReady?() } } }
    }
    private func finish(_ token: Int) {
        lock.lock(); if generation == token { scheduled = false }; lock.unlock()
    }
    private func report(_ error: Error, token: Int) {
        lock.lock()
        guard generation == token else { lock.unlock(); return }
        failed = true; scheduled = false; lock.unlock()
        DispatchQueue.main.async { if self.isCurrent(token) { self.onError?(error.localizedDescription) } }
    }
}
