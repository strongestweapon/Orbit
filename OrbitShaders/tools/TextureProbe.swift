import Foundation
import MetalKit
import ImageIO
import UniformTypeIdentifiers

struct TextureManifest: Decodable { let textures: [String:TextureDescriptor] }
struct ProbeFailure: Error { let message:String }

@main struct OrbitTextureProbe {
    static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let data=try Data(contentsOf:root.appendingPathComponent("OrbitTextures/manifest.json"))
        let manifest=try JSONDecoder().decode(TextureManifest.self,from:data)
        guard let device=MTLCreateSystemDefaultDevice(), let queue=device.makeCommandQueue() else { throw ProbeFailure(message:"GPU unavailable") }
        let source=OrbitTextureSource(device:device)
        source.onError={ print("DECODER ERROR:",$0) }
        let shader=try String(contentsOf:root.appendingPathComponent("OrbitShaders/metal/OrbitTexture.metal"))
        let options=MTLCompileOptions();options.fastMathEnabled=false
        let library=try await device.makeLibrary(source:shader,options:options)
        let pipeline=try await device.makeComputePipelineState(function:library.makeFunction(name:"orbit_texture_compute")!)
        func getFrame(_ id:String,_ d:TextureDescriptor,_ seconds:Double) async throws -> OrbitTextureFrame {
            let url=root.appendingPathComponent("OrbitTextures/textures/"+d.file)
            let index=d.kind == "image" ? 0 : min(d.frames-1,Int(floor(seconds.truncatingRemainder(dividingBy:d.duration)*d.fps)))
            source.request(sceneID:id,descriptor:d,url:url,seconds:seconds)
            for _ in 0..<500 {
                if let frame=source.snapshot(), frame.sceneID==id,frame.index==index { return frame }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            throw ProbeFailure(message:"Timed out: \(id) at \(index)")
        }
        func render(_ frame:OrbitTextureFrame,_ w:Int,_ h:Int,_ mode:Float,_ brightness:Float=1,_ warp:Float=0) throws -> Data {
            let values:[Float]=[Float(w),Float(h),mode,6,0.5,warp,0,0,brightness,3,0,0,0,0.128,0,0,1,0.8,0.25,0]
            let uniforms=device.makeBuffer(bytes:values,length:values.count*4,options:.storageModeShared)!
            let pixels=device.makeBuffer(length:w*h*4,options:.storageModeShared)!
            let command=queue.makeCommandBuffer()!;let encoder=command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline);encoder.setBuffer(pixels,offset:0,index:0)
            encoder.setBuffer(uniforms,offset:0,index:1);encoder.setTexture(frame.texture,index:0)
            encoder.dispatchThreads(MTLSize(width:w,height:h,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:8,depth:1))
            encoder.endEncoding();command.commit();command.waitUntilCompleted()
            guard command.status == .completed else { throw command.error ?? ProbeFailure(message:"GPU failed") }
            return Data(bytes:pixels.contents(),count:w*h*4)
        }
        func save(_ pixels:Data,_ w:Int,_ h:Int,_ file:String) {
            let provider=CGDataProvider(data:pixels as CFData)!
            let image=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
            let dest=CGImageDestinationCreateWithURL(root.appendingPathComponent("OrbitTextures/review/"+file) as CFURL,UTType.png.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(dest,image,nil);CGImageDestinationFinalize(dest)
        }
        var results:[[String:Any]]=[]
        for (id,d) in manifest.textures.sorted(by:{$0.key<$1.key}) {
            let start=Date();let first=try await getFrame(id,d,0)
            let initial=try render(first,d.width,d.height,0)
            let frame=try await getFrame(id,d,d.kind == "image" ? 0 : 6)
            let strip=try render(frame,15444,300,0);let packed=try render(frame,3840,2160,2)
            var error=0;var blankError=0
            strip.withUnsafeBytes { (s:UnsafeRawBufferPointer) in packed.withUnsafeBytes { (p:UnsafeRawBufferPointer) in
                for y in 0..<2160 { for x in 0..<3840 {
                    let row=y/300;let active=row<5 && x<3564 && (row<4 || x<1188)
                    for c in 0..<3 {
                        let value=Int(p[(y*3840+x)*4+c])
                        if active { error=max(error,abs(value-Int(s[((y%300)*15444+row*3564+x)*4+c]))) }
                        else {blankError=max(blankError,value)}
                    }
                }}
            }}
            guard error<=2 && blankError==0 else {throw ProbeFailure(message:"Packing: \(id) \(error) \(blankError)")}
            let black=try render(frame,256,64,0,0)
            guard black.enumerated().allSatisfy({$0.offset%4==3 || $0.element==0}) else {throw ProbeFailure(message:"Blackout failed")}
            let neutral=try render(frame,512,96,0);let warped=try render(frame,512,96,0,1,0.7)
            guard neutral != warped else {throw ProbeFailure(message:"Warp parameter has no effect")}
            save(try render(frame,1280,720,1),1280,720,id+"-ring.png")
            save(try render(frame,d.width,d.height,0),d.width,d.height,id+"-decoded-strip.png")
            if d.kind == "video" {
                _ = try await getFrame(id,d,d.duration-1/d.fps)
                let loop=try await getFrame(id,d,0)
                guard try render(loop,d.width,d.height,0)==initial else {throw ProbeFailure(message:"Loop frame mismatch")}
                try await Task.sleep(nanoseconds:80_000_000)
                guard source.snapshot()?.index==0 else {throw ProbeFailure(message:"Paused frame advanced")}
            }
            let result:[String:Any]=["scene":id,"kind":d.kind,"packingMaxByteError":error,"unusedPixelsBlack":true,
                "pauseAndLoopChecked":d.kind=="video","elapsedSeconds":Date().timeIntervalSince(start),"passed":true]
            results.append(result);print("PASS",id,"packing",error)
        }
        let report:[String:Any]=["device":device.name,"nativeDecoder":"AVAssetReader → CVMetalTexture → production Metal shader",
            "results":results,"hdmiOutputTested":false]
        let json=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try json.write(to:root.appendingPathComponent("OrbitTextures/review/validation.json"))
        source.reset();print("All native texture tests passed.")
    }
}
