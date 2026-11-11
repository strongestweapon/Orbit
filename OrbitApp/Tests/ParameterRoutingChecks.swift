import Foundation

@main struct ParameterRoutingChecks {
    static func main() throws {
        let now = Date()
        let first = SensorInput(name:"speed sensor",address:"/speed",minimum:0,maximum:100,value:75,receivedAt:now)
        let second = SensorInput(name:"light sensor",address:"/light",minimum:0,maximum:500,value:100,receivedAt:now)
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
        var bad = second;bad.minimum=500;bad.maximum=500
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

        let midi = ParameterOutputRoute()
        let oldOutput = """
        {"enabled":true,"transport":"midi","channel":2,"controller":74,"host":"127.0.0.1","port":9001,"address":"/orbit/value","minimum":0,"maximum":127}
        """
        var existingOutput = try JSONDecoder().decode(ParameterOutputRoute.self,from:Data(oldOutput.utf8))
        precondition(existingOutput.targetName == nil && existingOutput.configured == nil)
        precondition(existingOutput.isListed(defaultRoute:midi))
        existingOutput.enabled=false
        precondition(existingOutput.isListed(defaultRoute:midi),"Disabled custom endpoints must remain visible")
        var draftOutput=midi;draftOutput.configured=true;draftOutput.targetName="Live · Filter Cutoff"
        let reloadedOutput=try JSONDecoder().decode(ParameterOutputRoute.self,from:JSONEncoder().encode(draftOutput))
        precondition(reloadedOutput.isListed(defaultRoute:midi) && reloadedOutput.displayName=="Live · Filter Cutoff")
        precondition(!midi.isListed(defaultRoute:midi),"Input-only default route is not an output connection")
        var statusSensor=first;statusSensor.value=25;statusSensor.receivedAt=now
        precondition(statusSensor.receptionState(running:false,now:now) == .stopped)
        precondition(statusSensor.receptionState(running:true,now:now) == .receiving)
        precondition(statusSensor.receptionState(running:true,now:now.addingTimeInterval(90)) == .stale)
        statusSensor.receivedAt=nil
        precondition(statusSensor.receptionState(running:true,now:now) == .waiting,"Saved values must not look live")
        close(midi.mappedValue(1.5,spec:.find("speed"))!,64)
        close(midi.mappedValue(-0.5,spec:.find("hueShift"))!,0)
        close(midi.mappedValue(0.5,spec:.find("hueShift"))!,127)
        var osc = midi;osc.transport = .osc;osc.minimum = -20;osc.maximum = 20
        close(osc.mappedValue(0.75,spec:.find("brightness"))!,10)
        osc.port = 70000;precondition(osc.validationError != nil)
        osc.port = 9001;osc.address = "bad";precondition(osc.validationError != nil)
        let encoded = OSCEncoder.floatMessage(address:"/x",value:0.5)!
        precondition(Array(encoded) == [47,120,0,0,44,102,0,0,63,0,0,0])
        precondition(OSCEncoder.floatMessage(address:"/x",value:.nan) == nil)
        print("PASS: simultaneous routes, smoothing, stale/deleted inputs, legacy migration, connection list persistence, sensor states, MIDI scaling, OSC wire bytes")
    }
    static func close(_ a:Double,_ b:Double) {precondition(abs(a-b)<0.000001,"\(a) != \(b)")}
}
