import Foundation

/// Default OSC contract for integrators; no installation settings or invented sensors.
/// Uses the same address builder, trigger catalog, and route defaults as the app.
@main struct OSCReferenceExport {
    struct Manifest: Decodable {let scenes:[Scene]}
    struct Scene: Decodable {
        let id:String, name:String
        let parameters:[ShaderParameter]
        let compatibilityParameters:[ShaderParameter]?
        let testScene:Bool
        let texture:[String:JSONValue]?
    }
    // Texture metadata is irrelevant to the contract; only its presence matters.
    struct JSONValue: Decodable {
        init(from decoder:Decoder) throws { }
    }
    static func main() throws {
        let input=URL(fileURLWithPath:CommandLine.arguments[1])
        let output=URL(fileURLWithPath:CommandLine.arguments[2])
        let scenes=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:input)).scenes
        var globals:[[String:Any]]=scenes.map {[
            "id":$0.id,"title":$0.name,"inputAddress":"/orbit/scene/"+$0.id,
            "type":"Float","inputRange":[0.0,1.0],"inputCondition":">= 0.5, every packet; restart scene","output":NSNull()
        ]}
        for (id,title) in [("scene/next","다음 씬"),("scene/previous","이전 씬"),("play","재생"),("pause","일시정지"),("restart","현재 씬 처음부터")] {
            globals.append(["id":id,"title":title,"inputAddress":"/orbit/"+id,"type":"Float","inputRange":[0.0,1.0],"inputCondition":">= 0.5, every packet","output":NSNull()])
        }
        var entries:[[String:Any]]=[]
        for scene in scenes where !scene.testScene {
            for textured in (scene.texture == nil ? [false] : [false,true]) {
                let shader=scene.parameters+(scene.compatibilityParameters ?? [])
                let excluded=["density","turbulence","energy","rotation"]+(scene.id=="09_pulse_orbit" ? ["hueShift"] : [])
                let controls=textured ? ParameterSpec.all : ParameterSpec.all.filter {!excluded.contains($0.id)}+shader.enumerated().map {$0.element.spec(index:$0.offset)}+(scene.id=="09_pulse_orbit" ? PulseOrbitOutputs.specs : [])
                let specs=controls+SceneTrigger.catalog(scene:scene.id,textured:textured).map(\.spec)
                for spec in specs {
                    let route=ParameterRoute.defaults(scene:scene.id,parameter:spec.id,spec:spec)
                    let pulse=scene.id=="09_pulse_orbit" && !textured
                    var entry:[String:Any]=[
                        "scene":scene.id,"source":textured ? "original":"generated","id":spec.id,"title":spec.title,
                        "section":spec.outputOnly ? "simulationOutput":spec.isTrigger ? "event":(!textured && shader.contains {$0.id==spec.id}) ? "shader":"common",
                        "description":spec.detail,"type":"Float","argument":0,
                        "inputAddress":spec.outputOnly ? NSNull():SceneOSCAddress.input(scene:scene.id,parameter:spec.id,textured:textured),
                        "inputRange":spec.outputOnly ? []:[0.0,1.0],
                        "inputCondition":spec.outputOnly ? "no input":spec.isTrigger ? ">= 0.5, every packet":spec.isSwitch ? ">= 0.5 on; < 0.5 off":"normalized continuous value",
                        "outputAddress":route.output.address,"outputEnabledByDefault":false,
                        "outputModes":spec.supportsOutputMode ? ["continuous","trigger"]:["trigger"],
                        "outputRange":route.output.sendsTriggerValue(spec:spec) ? [1.0,1.0]:[0.0,1.0],
                        "triggerOutputValue":1.0,
                        "triggerOutputPolicy":pulse && PulseOrbitOutputs.isCrossing(spec.id) ? "Spontaneous crossings only: at most one bundle per 6 seconds; commands and send tests bypass":"one cue per event or continuous input packet",
                        "inputActiveWhen":"scene and source are selected; receiver running"
                    ]
                    if spec.isTrigger {entry["outputTiming"]="event"}
                    else if spec.eventOutput {entry["outputTiming"]=spec.id.hasPrefix("accent") ? "on a visual accent; metadata before the associated cue":"on actual simulation crossing"}
                    else {entry["outputTiming"]="continuous Float, or unit trigger on input packet; output-only continuous sources trigger when value changes"}
                    entries.append(entry)
                }
            }
        }
        let reference:[String:Any]=[
            "schemaVersion":2,"status":"Default OSC address reference, not an imported installation preset. Custom addresses are shown in the app OSC map.",
            "transport":"OSC over UDP; Float arguments only; MIDI output is not supported",
            "receiver":["bindAddress":"0.0.0.0","defaultPort":9000],
            "sender":["defaultHost":"127.0.0.1","defaultPort":9001,"scope":"one destination shared across scenes","bundle":"OSC immediate bundle; metadata before event"],
            "global":globals,"controls":entries,
            "pulseOrbit":["attractorField":"curved filaments converge within the LED band; strength controls path compression and glow; no point marker; logical position 0/1=12 o'clock, 0.25=3 o'clock before installation flips/offset",
                "idlePolicy":"Bright short strokes travel at unequal speeds without scheduled bursts. Existing continuous controls and event meanings are unchanged. Perpendicular marks are created only by explicit event commands, never by continuous values or automatic crossings.",
                "tracePolicy":["birth":"explicit departure, breakthrough or new-orbit command only","commandLifetimeSeconds":["departure":8.0,"breakthrough":3.6,"addLine":10.0,"completion":2.4],"capacity":16,"continuousMapping":"none; count, length, lifetime and motion are independent of continuous controls; event origin is captured at trigger time","completion":"gather and fade up to four nearby marks within 2.4 seconds; target is captured at trigger time","osc":"no additional OSC cues; existing event and parameter routes are unchanged"],
                "visualAccentLimit":24,"defaultOrbits":3,"maxOrbits":10,"spontaneousCrossingIntervalSeconds":6,"commandPolicy":"Each button press or OSC trigger creates an independent visual voice and immediate enabled OSC output; oldest voice replaced only beyond 24 active voices",
                "eventLifetimeSeconds":["departure":4.5,"breakthrough":3.6,"addLine":7.0,"completion":4.0],
                "dataNote":"Normalize upstream data before sending. Aggregated five-minute counts do not identify individual event timestamps."]
        ]
        let data=try JSONSerialization.data(withJSONObject:reference,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        try (data+Data([10])).write(to:output)
        print("Exported \(entries.count) OSC controls and \(globals.count) global commands")
    }
}
