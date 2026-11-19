import AppKit

@main struct InstallationModelChecks {
    static func main() throws {
        let bundle = Bundle(path:CommandLine.arguments[1])!
        let domain="studio.superless.Orbit.installation-tests-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        let model=OrbitModel(defaults:defaults,resources:bundle)
        precondition(model.scenes.count==8)
        model.selectedSceneID="03_aurora_ribbon"
        model.previewPolicy = .hideWhenFullscreen
        model.frameRate = .displayMaximum
        model.port="19009";model.playing=false;model.resumeOnLaunch=false
        model.setValue("brightness",0.37)
        model.globalOSC[0].address="/custom/restart"
        model.save()
        let restored=OrbitModel(defaults:defaults,resources:bundle)
        precondition(restored.selectedSceneID==model.selectedSceneID && !restored.playing)
        precondition(restored.port=="19009" && restored.frameRate == .displayMaximum)
        precondition(restored.previewPolicy == .hideWhenFullscreen && !restored.resumeOnLaunch)
        precondition(abs(restored.value("brightness")-0.37)<0.0001)
        precondition(restored.globalOSC[0].address=="/custom/restart")
        // The UI conversion changes neither stored native values nor the shader's available range.
        for scene in restored.scenes where !scene.testScene {
            restored.selectedSceneID=scene.id
            for spec in restored.parameterSpecs {
                let original=restored.baseParameterValue(spec.id)
                let unit=spec.normalized(original)
                precondition((0...1).contains(unit))
                restored.setNormalizedParameterValue(spec.id,unit)
                precondition(abs(restored.baseParameterValue(spec.id)-spec.clamp(original))<0.00001)
                restored.setNormalizedParameterValue(spec.id,1)
                precondition(abs(restored.baseParameterValue(spec.id)-spec.range.upperBound)<0.00001)
                restored.setNormalizedParameterValue(spec.id,unit)
            }
        }

        let cue=restored.globalOSC.first { $0.sceneID==restored.selectedSceneID }!
        for _ in 0..<3 { restored.receiveOSC(address:cue.address,values:[0.8]) }
        precondition(restored.globalReceipts[cue.id]?.triggerCount==3 && restored.playing)
        precondition(restored.uniforms(width:3840,height:2160,view:2)[3]<0.05,"Same-scene cue must reset clock")
        restored.receiveOSC(address:cue.address,values:[0.49])
        precondition(restored.globalReceipts[cue.id]?.triggerCount==3)
        restored.receiveOSC(address:restored.sensors[0].address,values:[0.7])
        precondition(restored.sensors[0].value==0.7)
        restored.save()
        var stored=try JSONDecoder().decode(StoredSettings.self,from:defaults.data(forKey:"OrbitSettings.v1")!)
        precondition(stored.sensors[0].value==nil && stored.sensors[0].receivedAt==nil)
        stored.installation?.displayUUID="missing-monitor-uuid"
        defaults.set(try JSONEncoder().encode(stored),forKey:"OrbitSettings.v1")
        let fallback=OrbitModel(defaults:defaults,resources:bundle)
        precondition(fallback.selectedDisplayID==0 && fallback.displayFallback)
        fallback.save()
        let savedAgain=try JSONDecoder().decode(StoredSettings.self,from:defaults.data(forKey:"OrbitSettings.v1")!)
        precondition(savedAgain.installation?.displayUUID=="missing-monitor-uuid","Fallback must retain preferred monitor identity")
        // Reconnected monitors are matched by stable UUID rather than a transient display ID.
        if let display=fallback.displays.first {
            fallback.selectedDisplayID=display.id;fallback.save()
            let connected=OrbitModel(defaults:defaults,resources:bundle)
            precondition(connected.selectedDisplayID==display.id && !connected.displayFallback)
        }
        fallback.playing=true;fallback.oscRunning=true;fallback.controlOutputEnabled=true
        fallback.shutdownForTermination()
        let beforeCleanup=defaults.data(forKey:"OrbitSettings.v1")!
        let retained=try JSONDecoder().decode(StoredSettings.self,from:beforeCleanup)
        precondition(retained.installation?.oscReceiving==true && retained.installation?.controlSending==true)
        precondition(fallback.isShuttingDown && !fallback.oscRunning && !fallback.controlOutputEnabled && !fallback.outputOpen)
        fallback.save();fallback.shutdownForTermination();fallback.restoreSessionOnce()
        fallback.receiveOSC(address:cue.address,values:[0.8])
        precondition(defaults.data(forKey:"OrbitSettings.v1")==beforeCleanup,"Shutdown must preserve the pre-cleanup snapshot")
        precondition(fallback.globalReceipts.isEmpty,"Late OSC must not restart a closing session")
        print("PASS: model save/reload, scene controls, FPS, OSC config, repeated scene restarts, missing/reconnected monitor, no stale sensor state")
    }
}
