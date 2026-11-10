import Foundation
import CoreGraphics

@main struct OutputGeometryChecks {
    static func main() {
        let cases: [(CGSize, CGRect, CGSize)] = [
            (CGSize(width:3840,height:2160),CGRect(x:0,y:0,width:3840,height:2160),CGSize(width:3840,height:2160)),
            (CGSize(width:1920,height:1080),CGRect(x:0,y:0,width:1920,height:1080),CGSize(width:1920,height:1080)),
            (CGSize(width:3456,height:2234),CGRect(x:0,y:145,width:3456,height:1944),CGSize(width:3456,height:1944)),
            (CGSize(width:3440,height:1440),CGRect(x:440,y:0,width:2560,height:1440),CGSize(width:2560,height:1440)),
            (CGSize(width:1440,height:2560),CGRect(x:0,y:875,width:1440,height:810),CGSize(width:1440,height:810)),
            (CGSize(width:1920,height:1200),CGRect(x:0,y:60,width:1920,height:1080),CGSize(width:1920,height:1080))
        ]
        for (size,expected,renderSize) in cases {
            let rect=OutputGeometry.fittedRect(in:CGRect(origin:.zero,size:size))
            requireClose(rect.minX,expected.minX);requireClose(rect.minY,expected.minY)
            requireClose(rect.width,expected.width);requireClose(rect.height,expected.height)
            precondition(OutputGeometry.automaticSize(in:size)==renderSize)
            requireClose(rect.width/rect.height,16.0/9.0)
            precondition(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= size.width+0.001 && rect.maxY <= size.height+0.001)
        }
        let logical=OutputGeometry.fittedRect(in:CGRect(x:0,y:0,width:1728,height:1117))
        let retina=OutputGeometry.automaticSize(in:CGSize(width:logical.width*2,height:logical.height*2))
        precondition(retina==CGSize(width:3456,height:1944))
        let presets:[OutputResolution:CGSize] = [.hd:CGSize(width:1280,height:720),.fullHD:CGSize(width:1920,height:1080),
            .qhd:CGSize(width:2560,height:1440),.uhd:CGSize(width:3840,height:2160)]
        for (mode,size) in presets { precondition(mode.size(availablePixels:CGSize(width:800,height:600),customWidth:123)==size) }
        for (input,expected) in [(0,320),(319,320),(1921,1920),(2560,2560),(9000,7680)] {
            let size=OutputResolution.custom.size(availablePixels:.zero,customWidth:input)
            precondition(size.width==CGFloat(expected));requireClose(size.width/size.height,16.0/9.0)
        }
        precondition(OutputGeometry.fittedRect(in:.zero) == .zero)
        precondition(OutputGeometry.automaticSize(in:.zero) == .zero)
        precondition(OutputGeometry.automaticSize(in:CGSize(width:CGFloat.infinity,height:100)) == .zero)
        print("PASS: 4K/HD, Retina, 16:10, ultrawide, portrait, custom bounds and empty layout")
    }
    static func requireClose(_ a:CGFloat,_ b:CGFloat) { precondition(abs(a-b)<0.001,"\(a) != \(b)") }
}
