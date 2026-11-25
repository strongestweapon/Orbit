import AppKit

@main struct MappingOverviewChecks {
    static func main() throws {
        let domain="studio.superless.Orbit.mapping-overview-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:domain)!
        defer {defaults.removePersistentDomain(forName:domain)}
        let resources=Bundle(path:CommandLine.arguments[1])!
        func makeModel() -> OrbitModel {
            OrbitModel(defaults:defaults,resources:resources,controlOutput:ControlOutput())
        }
        let model=makeModel();defer {model.shutdownForTermination()}
        model.playing=false;model.selectedSceneID=PulseOrbitSimulation.sceneID
        let pulse=PulseOrbitSimulation.sceneID,addLine=SceneTrigger.addLineID
        func row(_ scene: String,_ key: String,_ textured: Bool = false) -> MappingRow {
            model.mappingRows.first {$0.sceneID==scene && $0.spec?.id==key && $0.textured==textured}!
        }
        // Brand-new commands and output signals must be discoverable before any mapping is saved.
        let initial=model.mappingRows
        precondition(Set(initial.map(\.id)).count==initial.count,"Duplicate overview IDs")
        precondition(initial.filter {$0.spec?.isTrigger == true && !$0.textured}.count==25)
        precondition(initial.filter {$0.globalID != nil}.count==model.globalOSC.count)
        precondition(!row(pulse,addLine).configured && row(pulse,addLine).isEvent)
        precondition(row(pulse,addLine).inputRangeLabel == "OSC Float 0.0–1.0")
        precondition(row(pulse,addLine).conditionLabel == "≥ 0.5 수신마다 1회")
        precondition(initial.first {$0.globalID != nil}!.conditionLabel == "≥ 0.5 수신마다 1회")
        precondition(row(pulse,PulseOrbitOutputs.trigger).spec?.outputOnly == true)
        precondition(!initial.contains {$0.sceneID==pulse && $0.textured},"Phantom texture controls")
        precondition(!initial.contains {$0.globalID == nil && $0.configured},"Defaults are not configured connections")

        // A shared filter must retain both directions of a continuous-in/trigger-out route.
        precondition(row(pulse,"inertia").matchesSignalType(1) && !row(pulse,"inertia").matchesSignalType(2))
        model.setRoute("inertia") {$0.output.mode = .trigger}
        precondition(row(pulse,"inertia").matchesSignalType(1) && row(pulse,"inertia").matchesSignalType(2))
        precondition(!initial.first {$0.globalID != nil}!.matchesSignalType(1))
        precondition(row(pulse,PulseOrbitOutputs.trigger).matchesSignalType(2) && !row(pulse,PulseOrbitOutputs.trigger).matchesSignalType(1))
        model.setRoute("inertia") {$0.output.mode = .continuous}

        // The same route must update immediately from either entry point, with scene-specific defaults.
        model.setRoute(addLine) {$0.input.directOSCAddress="/qa/login"}
        precondition(row(pulse,addLine).configured && row(pulse,addLine).address=="/qa/login")
        model.setRoute(addLine,sceneID:pulse,textured:false) {
            $0.output.enabled=true;$0.output.transport = .osc;$0.output.address="/qa/add-line";$0.output.maximum=99
        }
        precondition(model.route(for:addLine).output.address=="/qa/add-line" && model.route(for:addLine).output.maximum==1)
        precondition(row(pulse,addLine).outputRangeLabel == "OSC Float 1.0 · 1회")
        model.setRoute(addLine) {$0.input.directOSCAddress="/qa/renamed-login"}
        precondition(row(pulse,addLine).address.contains("/qa/renamed-login"))
        model.setRoute(addLine) {$0.input.directOSCArgument=2}
        precondition(row(pulse,addLine).route!.input.oscArgument==2)
        model.clearControlOutput(addLine,sceneID:pulse,textured:false)
        precondition(!row(pulse,addLine).route!.output.enabled && row(pulse,addLine).route!.input.receivesDirectOSC)

        // Editing an inactive scene must not clear current events, reset lines, alter values or swap sources.
        model.triggerParameter(addLine);model.triggerParameter(addLine)
        precondition(model.pulseLineCount==5)
        let count=model.parameterEventCount(addLine),values=model.parameterValues
        let other=model.scenes.first {!$0.testScene && $0.texture != nil}!.id
        let otherEvent=model.triggers(for:other,textured:false)[0].id
        let before=try JSONEncoder().encode(model.activeSettings)
        model.setRoute(otherEvent,sceneID:other,textured:false) {
            $0.input.sourceParameter="brightness";$0.input.enabled=true;$0.output.enabled=true;$0.output.address="/qa/other"
        }
        precondition(row(other,otherEvent).route!.input.behavior == .threshold)
        model.setRoute(otherEvent,sceneID:other,textured:false) {
            var event=$0.input.eventSettings;event.threshold = .init(level:0.725,hysteresis:0.125);$0.input.event=event
        }
        precondition(row(other,otherEvent).inputRangeLabel == "영상 연속값 0.0–1.0")
        precondition(row(other,otherEvent).conditionLabel == "직접 ≥ 0.5 수신마다 1회\n영상 값: ≥ 0.725 진입 시 1회\n≤ 0.6 이후 다시 진입하면 반복")
        model.setRoute("speed",sceneID:other,textured:false) {$0.input.minimum=0.6;$0.input.maximum=2.4;$0.input.enabled=true}
        precondition(row(other,"speed").conditionLabel == "0.0 → 1.0","Direct values stay normalized to 0…1")
        model.globalOSC[0].triggerMode = .threshold
        model.globalOSC[0].threshold = .init(level:0.8,hysteresis:0)
        precondition(model.mappingRows.first {$0.globalID==model.globalOSC[0].id}!.conditionLabel == "≥ 0.8 진입 시 1회\n< 0.8 이후 다시 진입하면 반복","Zero hysteresis still requires going below the threshold")
        model.setNormalizedParameterValue("brightness",0.23,sceneID:other,textured:false)
        model.setRoute("brightness",sceneID:other,textured:true) {
            $0.input.directOSCAddress="/qa/texture/in";$0.output.address="/qa/texture"
        }
        model.setNormalizedParameterValue("brightness",0.71,sceneID:other,textured:true)
        precondition(abs(model.baseParameterValue("brightness",sceneID:other,textured:false)-0.23)<0.00001)
        precondition(abs(model.baseParameterValue("brightness",sceneID:other,textured:true)-0.71)<0.00001)
        precondition(row(other,"brightness").route!.input.directOSCAddress==nil && row(other,"brightness",true).route!.input.directOSCAddress=="/qa/texture/in")
        precondition(model.selectedSceneID==pulse && !model.usesTexture && model.pulseLineCount==5)
        precondition(model.parameterEventCount(addLine)==count && model.parameterValues==values)
        let after=try JSONEncoder().encode(model.activeSettings)
        let beforeObject=try JSONSerialization.jsonObject(with:before) as! [String:Any]
        let afterObject=try JSONSerialization.jsonObject(with:after) as! [String:Any]
        precondition(NSDictionary(dictionary:beforeObject).isEqual(to:afterObject))

        // Duplicate-output validation is scoped to the scene/source being edited.
        model.setRoute("brightness",sceneID:other,textured:false) {
            $0.output.enabled=true;$0.output.transport = .osc;$0.output.address="/qa/other"
        }
        precondition(model.outputIssue(for:otherEvent,sceneID:other,textured:false) != nil)
        precondition(model.outputIssue(for:addLine)==nil)
        model.clearControlOutput("brightness",sceneID:other,textured:false)
        precondition(model.outputIssue(for:otherEvent,sceneID:other,textured:false)==nil)
        precondition(row(other,"brightness",true).route!.output.address=="/qa/texture")

        // A converted legacy event is still listed next to the current catalog after a restart.
        let migrated="trigger.parameter.brightness"
        model.setRoute(migrated,sceneID:other,textured:false) {$0.input.mode = .event;$0.input.legacyTarget=0.8}
        precondition(row(other,migrated).isEvent)
        model.save()
        let restored=makeModel();defer {restored.shutdownForTermination()}
        precondition(restored.mappingRows.contains {$0.sceneID==other && $0.spec?.id==migrated})
        precondition(restored.route(for:otherEvent,sceneID:other,textured:false).output.address=="/qa/other")
        precondition(restored.route(for:"brightness",sceneID:other,textured:true).output.address=="/qa/texture")
        precondition(restored.mappingRows.contains {$0.sceneID==pulse && $0.spec?.id==addLine})
        print("PASS: catalog completeness, live mapping updates, scene/source isolation, output validation and persisted mappings")
    }
}
