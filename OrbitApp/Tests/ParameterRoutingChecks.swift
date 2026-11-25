import Foundation

@main struct ParameterRoutingChecks {
    static func main() throws {
        let now = Date()
        let first = SensorInput(name:"speed sensor",address:"/speed",value:0.75,receivedAt:now)
        let second = SensorInput(name:"light sensor",address:"/light",value:0.2,receivedAt:now)
        var speed = ParameterRoute.defaults(scene:"scene",parameter:"speed")
        speed.input = .init(enabled:true,sensorID:first.id,minimum:0,maximum:3,smoothingSeconds:0)
        var light = ParameterRoute.defaults(scene:"scene",parameter:"brightness")
        light.input = .init(enabled:true,sensorID:second.id,minimum:1,maximum:0,smoothingSeconds:0)
        var hue = ParameterRoute.defaults(scene:"scene",parameter:"hueShift")
        hue.input = .init(enabled:true,sensorID:first.id,minimum:-0.5,maximum:0.5,smoothingSeconds:0)
        let routes = ["speed":speed,"brightness":light,"hueShift":hue]
        let base = ["speed":1.0,"brightness":0.4,"hueShift":0.0,"energy":0.6]
        var resolver = ParameterResolver()
        let values = resolver.resolve(base:base,routes:routes,sensors:[first,second],now:now,delta:0.1)
        close(values["speed"]!,2.25);close(values["brightness"]!,0.8);close(values["hueShift"]!,0.25);close(values["energy"]!,0.6)
        let stale = resolver.resolve(base:base,routes:routes,sensors:[first,second],now:now.addingTimeInterval(91),delta:1)
        precondition(stale == base)
        let deleted = resolver.resolve(base:base,routes:routes,sensors:[],now:now,delta:1)
        precondition(deleted == base)

        speed.input.smoothingSeconds = 6
        resolver.reset()
        let smoothed = resolver.resolve(base:base,routes:["speed":speed,"brightness":light],sensors:[first,second],now:now,delta:2)
        close(smoothed["speed"]!,1+(2.25-1)*(1-exp(-1)))
        close(smoothed["brightness"]!,0.8)
        let disabled = resolver.resolve(base:base,routes:[:],sensors:[first,second],now:now,delta:0)
        precondition(disabled == base)
        var bad = second;bad.value = .nan
        close(resolver.resolve(base:base,routes:["brightness":light],sensors:[bad],now:now,delta:1)["brightness"]!,0.4)

        let old = """
        {"values":{"energy":0.4},"speed":1,"mapping":{"sensorID":"\(first.id.uuidString)","target":"speed","minimum":0.2,"maximum":2.8,"smoothingSeconds":7,"enabled":true},"textureMapping":{"target":"brightness","minimum":0.1,"maximum":0.8,"smoothingSeconds":4,"enabled":true}}
        """
        var scene = try JSONDecoder().decode(SceneSettings.self,from:Data(old.utf8))
        scene.migrateRoutes(scene:"old")
        precondition(scene.parameterRoutes?["speed"]?.input.sensorID == first.id)
        precondition(scene.textureParameterRoutes?["brightness"]?.input.enabled == true)
        precondition(scene.parameterRoutes?["speed"]?.output.enabled == false)
        scene.parameterRoutes?["speed"]?.output.enabled = true
        scene.parameterRoutes?["speed"]?.output.controller = 45
        scene.migrateRoutes(scene:"old")
        let decoded = try JSONDecoder().decode(SceneSettings.self,from:JSONEncoder().encode(scene))
        precondition(decoded.parameterRoutes?["speed"]?.output.controller == 45)
        precondition(decoded.textureParameterRoutes?["brightness"]?.input.maximum == 0.8)

        let defaults = ParameterOutputRoute()
        let oldOutput = """
        {"enabled":true,"transport":"midi","channel":2,"controller":74,"host":"127.0.0.1","port":9001,"address":"/orbit/value","minimum":0,"maximum":127}
        """
        var existingOutput = try JSONDecoder().decode(ParameterOutputRoute.self,from:Data(oldOutput.utf8))
        precondition(existingOutput.targetName == nil && existingOutput.configured == nil)
        precondition(existingOutput.isListed(defaultRoute:defaults))
        existingOutput.enabled=false
        precondition(existingOutput.isListed(defaultRoute:defaults),"Disabled custom endpoints must remain visible")
        var draftOutput=defaults;draftOutput.configured=true;draftOutput.targetName="Live · Filter Cutoff"
        let reloadedOutput=try JSONDecoder().decode(ParameterOutputRoute.self,from:JSONEncoder().encode(draftOutput))
        precondition(reloadedOutput.isListed(defaultRoute:defaults) && reloadedOutput.displayName==reloadedOutput.address)
        precondition(!defaults.isListed(defaultRoute:defaults),"Input-only default route is not an output connection")
        var statusSensor=first;statusSensor.value=25;statusSensor.receivedAt=now
        precondition(statusSensor.receptionState(running:false,now:now) == .stopped)
        precondition(statusSensor.receptionState(running:true,now:now) == .receiving)
        precondition(statusSensor.receptionState(running:true,now:now.addingTimeInterval(90)) == .stale)
        statusSensor.receivedAt=nil
        precondition(statusSensor.receptionState(running:true,now:now) == .waiting,"Saved values must not look live")
        close(defaults.mappedValue(1.5,spec:.find("speed"))!,0.5)
        close(defaults.mappedValue(-0.5,spec:.find("hueShift"))!,0)
        close(defaults.mappedValue(0.5,spec:.find("hueShift"))!,1)
        var osc = defaults;osc.transport = .osc;osc.minimum = -20;osc.maximum = 20
        close(osc.mappedValue(0.75,spec:.find("brightness"))!,10)
        osc.port = 70000;precondition(osc.validationError != nil)
        osc.port = 9001;osc.address = "bad";precondition(osc.validationError != nil)
        let encoded = OSCEncoder.floatMessage(address:"/x",value:0.5)!
        precondition(Array(encoded) == [47,120,0,0,44,102,0,0,63,0,0,0])
        precondition(OSCEncoder.floatMessage(address:"/x",value:.nan) == nil)
        // Old persisted routes retain continuous semantics; new event state never leaks into JSON.
        precondition(existingOutput.behavior == .continuous)
        precondition(existingOutput.validationError != nil, "Unconverted legacy MIDI must never transmit")
        let converted=existingOutput.oscOnly()
        precondition(converted.transport == .osc && converted.address==existingOutput.address)
        close(converted.minimum,0);close(converted.maximum,1)
        precondition(converted.oscOnly()==converted,"Migration must be idempotent")
        var reversed=existingOutput;reversed.minimum=127;reversed.maximum=32
        close(reversed.oscOnly().minimum,1);close(reversed.oscOnly().maximum,32.0/127.0)
        precondition(osc.oscOnly()==osc,"Custom OSC ranges must be preserved")
        scene.parameterRoutes?["speed"]?.output=existingOutput
        scene.textureParameterRoutes?["brightness"]?.output=reversed
        scene.migrateOSCOutputs()
        precondition(scene.parameterRoutes?["speed"]?.output==converted)
        precondition(scene.textureParameterRoutes?["brightness"]?.output==reversed.oscOnly())
        let migrated=try JSONDecoder().decode(SceneSettings.self,from:JSONEncoder().encode(scene))
        precondition(migrated.parameterRoutes?["speed"]?.output.transport == .osc)

        var cue=ParameterInputRoute(enabled:true,sensorID:first.id,minimum:0.2,maximum:0.9,smoothingSeconds:8)
        cue.mode = .event;cue.event = .init(threshold:.init(),attack:0.1,hold:0.1,release:0.2)
        var events=ParameterEvents()
        for value in [0.5,1.0,1.0] { precondition(events.accepts("brightness",value:value,route:cue)) }
        precondition(!events.accepts("brightness",value:0.49,route:cue))
        precondition(!events.accepts("brightness",value:.nan,route:cue))
        events.fire("brightness",route:cue,at:10)
        let eventRoutes=["brightness":ParameterRoute(input:cue)]
        close(events.apply(base,routes:eventRoutes,specs:[.find("brightness")],at:10)["brightness"]!,0.2)
        close(events.apply(base,routes:eventRoutes,specs:[.find("brightness")],at:10.15)["brightness"]!,0.9)
        close(events.apply(base,routes:eventRoutes,specs:[.find("brightness")],at:10.3)["brightness"]!,0.55)
        close(events.apply(base,routes:eventRoutes,specs:[.find("brightness")],at:10.5)["brightness"]!,0.2)
        events.fire("brightness",route:cue,at:11)
        events.fire("brightness",route:cue,at:11.12)
        precondition(events.counts["brightness"]==3)
        close(events.apply(base,routes:eventRoutes,specs:[.find("brightness")],at:11.17)["brightness"]!,0.55)
        var manual=cue;manual.enabled=false
        events.fire("brightness",route:manual,at:20)
        close(events.apply(base,routes:["brightness":ParameterRoute(input:manual)],specs:[.find("brightness")],at:20.15)["brightness"]!,0.9)
        close(events.apply(base,routes:["brightness":ParameterRoute(input:manual)],specs:[.find("brightness")],at:20.6)["brightness"]!,0.2)
        var threshold=ThresholdLatch()
        let levels:[Double]=[0.2,0.49,0.5,0.8,1,0.49,0.5,0.44,0.51]
        precondition(levels.map {threshold.accept($0,settings:.init())} == [false,false,true,false,false,false,false,false,true])
        var prime=ThresholdLatch()
        precondition(!prime.accept(1,settings:.init(),fireFirst:false))
        precondition(!prime.accept(1,settings:.init()))
        precondition(!prime.accept(0.1,settings:.init()))
        precondition(prime.accept(0.5,settings:.init()))
        var thresholdCue=cue;thresholdCue.mode = .threshold
        events.reset()
        precondition(events.accepts("brightness",value:0.8,route:thresholdCue))
        precondition(!events.accepts("brightness",value:0.8,route:thresholdCue))
        let eventReload=try JSONDecoder().decode(ParameterInputRoute.self,from:JSONEncoder().encode(cue))
        precondition(eventReload==cue)
        var eventResolver=ParameterResolver()
        close(eventResolver.resolve(base:base,routes:eventRoutes,sensors:[first],now:now,delta:2)["brightness"]!,base["brightness"]!)
        // Existing event-on-slider mappings migrate to their own command IDs exactly once.
        var legacyEvent=ParameterRoute.defaults(scene:"sample",parameter:"brightness")
        legacyEvent.input=cue;legacyEvent.output.enabled=true;legacyEvent.output.mode = .event
        legacyEvent.output.address="/saved/cue"
        var separated=SceneSettings(values:["brightness":0.4],speed:1,parameterRoutes:["brightness":legacyEvent])
        separated.separateTriggerRoutes(scene:"sample",specs:[.find("brightness")],textured:false)
        let moved=separated.parameterRoutes!["trigger.parameter.brightness"]!
        precondition(moved.input.sensorID==cue.sensorID && moved.input.enabled && moved.input.legacyTarget==0.9)
        precondition(moved.output.enabled && moved.output.address=="/saved/cue")
        precondition(separated.parameterRoutes!["brightness"]!.input.behavior == .continuous)
        precondition(!separated.parameterRoutes!["brightness"]!.input.enabled && !separated.parameterRoutes!["brightness"]!.output.enabled)
        close(Double(separated.values["brightness"]!),0.2)
        let once=separated.parameterRoutes
        separated.separateTriggerRoutes(scene:"sample",specs:[.find("brightness")],textured:false)
        precondition(once==separated.parameterRoutes)
        precondition(ParameterSpec.find("trigger.discharge").isTrigger && !ParameterSpec.find("brightness").isTrigger)
        print("PASS: simultaneous routes, smoothing, stale/deleted inputs, legacy migration, connection list persistence, sensor states, legacy MIDI to OSC conversion, OSC float scaling and wire bytes")
    }
    static func close(_ a:Double,_ b:Double) {precondition(abs(a-b)<0.000001,"\(a) != \(b)")}
}
