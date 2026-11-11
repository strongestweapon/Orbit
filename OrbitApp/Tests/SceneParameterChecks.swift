import Foundation

@main struct SceneParameterChecks {
    struct Manifest: Decodable { let scenes: [Scene] }
    struct Scene: Decodable {
        let id: String
        let parameters: [ShaderParameter]
        let compatibilityParameters: [ShaderParameter]?
        var allParameters: [ShaderParameter] { parameters + (compatibilityParameters ?? []) }
        let testScene: Bool
    }
    static func main() throws {
        let url = URL(fileURLWithPath:CommandLine.arguments[1])
        let scenes = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:url)).scenes
        for scene in scenes where !scene.testScene {
            let specs = scene.allParameters.enumerated().map { $0.element.spec(index:$0.offset) }
            precondition(Set(specs.map(\.id)).count == specs.count)
            precondition(Set(scene.allParameters.map(\.uniform)).count == scene.allParameters.count)
            precondition(scene.parameters.filter(\.quick).count == 1)
            var old = SceneSettings(values:["density":0.17,"turbulence":0.38,"energy":0.91,"texture.energy":0.72],speed:1)
            var route = ParameterRoute.defaults(scene:scene.id,parameter:"energy")
            route.input.enabled = true;route.output.enabled = true;route.output.controller = 74
            route.output.address = "/existing/audio/address"
            old.parameterRoutes = ["energy":route];old.textureParameterRoutes = ["energy":route]
            old.migrateShaderParameters(scene.allParameters)
            let energy = scene.allParameters.first { $0.legacyKey == "energy" }!
            close(Double(old.values[energy.id]!),0.91,tolerance:0.000001)
            precondition(old.parameterRoutes?[energy.id]?.output.controller == 74)
            precondition(old.parameterRoutes?[energy.id]?.output.address == "/existing/audio/address")
            precondition(old.parameterRoutes?["energy"] == nil)
            precondition(old.textureParameterRoutes?["energy"]?.output.controller == 74)
            old.values[energy.id] = 0.24
            old.migrateShaderParameters(scene.allParameters)
            close(Double(old.values[energy.id]!),0.24,tolerance:0.000001)
            for (index,p) in scene.allParameters.enumerated() {
                let spec = p.spec(index:index)
                close(spec.clamp(p.defaultValue),p.defaultValue)
                let output = ParameterRoute.defaults(scene:scene.id,parameter:p.id,spec:spec).output
                precondition(output.controller == p.midiCC)
                close(output.mappedValue(p.minimum,spec:spec)!,0)
                close(output.mappedValue(p.maximum,spec:spec)!,127)
            }
            let encoded = try JSONEncoder().encode(old)
            let restored = try JSONDecoder().decode(SceneSettings.self,from:encoded)
            precondition(restored.parameterRoutes == old.parameterRoutes)
        }
        let counts = Dictionary(uniqueKeysWithValues:scenes.filter { !$0.testScene }.map { ($0.id,$0.parameters.count) })
        precondition(counts["05_cyan_halo"] == 3 && counts["07_spectral_fragments"] == 7)
        precondition(Set(counts.values).count >= 4)
        let spectral = scenes.first { $0.id == "07_spectral_fragments" }!
        let specs = spectral.parameters.enumerated().map { $0.element.spec(index:$0.offset) }
        let sensor = SensorInput(name:"test",address:"/test",value:50,receivedAt:Date())
        var routes:[String:ParameterRoute] = [:]
        for spec in specs where ["barLength","barWidth"].contains(spec.id) {
            var route = ParameterRoute.defaults(scene:spectral.id,parameter:spec.id,spec:spec)
            route.input.enabled=true;route.input.sensorID=sensor.id;route.input.smoothingSeconds=0
            routes[spec.id]=route
        }
        var resolver=ParameterResolver()
        let values=resolver.resolve(base:["barLength":1,"barWidth":1],routes:routes,sensors:[sensor],now:Date(),delta:1,specs:specs)
        close(values["barLength"]!,0.75);close(values["barWidth"]!,2.125)
        precondition(!specs.contains { $0.id == "energy" })
        print("PASS: variable-size scene catalogs, stable MIDI defaults, semantic ranges, legacy values/routes/endpoints preserved, texture isolation, save/reload, independent bar length/width sensor mapping")
    }
    static func close(_ a:Double,_ b:Double,tolerance:Double=0.00000001) {precondition(abs(a-b)<tolerance,"\(a) != \(b)")}
}
