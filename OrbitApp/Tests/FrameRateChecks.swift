import Foundation

@main struct FrameRateChecks {
    static func main() {
        var preview=FrameRateMeter(),output=FrameRateMeter()
        precondition(preview.framesPerSecond(at:100) == nil)
        for i in 0...120 {
            let time=100+Double(i)/60
            preview.record(completedAt:time)
            if i%2 == 0 {output.record(completedAt:time)}
        }
        close(preview.framesPerSecond(at:102),60)
        close(output.framesPerSecond(at:102),30)
        // Delayed main-thread delivery does not change the timestamps' frame intervals.
        close(preview.framesPerSecond(at:102.3),60)
        for invalid in [0.0,Double.nan,Double.infinity,101.0,102.0] {preview.record(completedAt:invalid)}
        close(preview.framesPerSecond(at:102.3),60)
        close(preview.framesPerSecond(at:103.01),0)
        preview.record(completedAt:104)
        precondition(preview.framesPerSecond(at:104) == nil)
        for i in 1...30 {preview.record(completedAt:104+Double(i)/60)}
        close(preview.framesPerSecond(at:104.5),60)
        output.reset()
        precondition(output.framesPerSecond(at:105) == nil)
        close(preview.framesPerSecond(at:104.5),60)
        // A sustained change in refresh rate replaces the earlier window.
        for i in 1...90 {preview.record(completedAt:104.5+Double(i)/30)}
        close(preview.framesPerSecond(at:107.5),30)
        print("PASS: independent 60/30 FPS, delayed callbacks, invalid/duplicate frames, stale zero, restart warmup, session reset, refresh-rate change")
    }
    static func close(_ value:Double?,_ expected:Double) {
        precondition(value != nil && abs(value!-expected)<0.00001,"\(String(describing:value)) != \(expected)")
    }
}
