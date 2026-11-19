import Foundation

@main struct InstallationChecks {
    static func main() throws {
        let cue=GlobalOSCMapping(address:"/orbit/scene/next",action:.next)
        let values=[0.49,0.5,0.8,0.8,0.0,1.0]
        precondition(values.filter { cue.accepts(address:cue.address,values:[$0]) }.count == 4,
                     "Every high packet must fire, including consecutive identical values")
        precondition(!cue.accepts(address:"/other",values:[1]))
        precondition(!cue.accepts(address:cue.address,values:[.nan]))
        precondition(!cue.accepts(address:cue.address,values:[]))
        var disabled=cue;disabled.enabled=false
        precondition(!disabled.accepts(address:cue.address,values:[1]))
        precondition(OSCValue.normalized(-0.1)==0 && OSCValue.normalized(2)==1 && OSCValue.normalized(.infinity)==nil)
        let bytes=OSCEncoder.floatMessage(address:"/cue",value:0.8)!
        let decoded=OSCDecoder.decode(bytes)
        precondition(decoded.count==1 && abs(decoded[0].values[0]-0.8)<0.0001)
        var integer=bytes;integer[9]=105 // /cue padded to 8 bytes; change ,f to ,i
        precondition(OSCDecoder.decode(integer)[0].values[0].isNaN,"Integer must not masquerade as normalized float")
        let saved=InstallationSettings(displayUUID:"stable-monitor-id",selectedSceneID:"scene",
            frameRate:"displayMaximum",previewPolicy:.hideWhenFullscreen,playing:false,resumeOnLaunch:true,
            oscReceiving:true,controlSending:true,outputOpen:true,outputFullscreen:true)
        let restored=try JSONDecoder().decode(InstallationSettings.self,from:JSONEncoder().encode(saved))
        precondition(restored.displayUUID==saved.displayUUID && restored.outputFullscreen==true)
        precondition(restored.previewPolicy == .hideWhenFullscreen)
        let legacy=try JSONDecoder().decode(InstallationSettings.self,from:Data("{}".utf8))
        precondition(legacy.previewPolicy==nil)
        precondition(PreviewPolicy.always.renders(outputOpen:true,fullscreen:true))
        precondition(PreviewPolicy.hideWhenFullscreen.renders(outputOpen:true,fullscreen:false))
        precondition(!PreviewPolicy.hideWhenFullscreen.renders(outputOpen:true,fullscreen:true))
        precondition(PreviewPolicy.hideWhenFullscreen.renders(outputOpen:false,fullscreen:false))
        precondition(!PreviewPolicy.off.renders(outputOpen:false,fullscreen:false))
        for requested:Float in [0,1,2] { precondition(RenderViewMode.resolved(requested,isOutput:true)==2) }
        print("PASS: float OSC, repeated high cues, invalid values, preference round-trip, preview policy, forced LED output")
    }
}
