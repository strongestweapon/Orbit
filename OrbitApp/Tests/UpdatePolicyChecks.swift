import AppKit
import Sparkle

@main struct UpdatePolicyChecks {
    @MainActor static func main() {
        let bundle = Bundle(path:CommandLine.arguments[1])!
        let id = bundle.bundleIdentifier!
        precondition(id == "studio.superless.Orbit.UpdateTest", "Use an isolated fixture, never production preferences")
        let defaults = UserDefaults(suiteName:id)!
        let previous = defaults.persistentDomain(forName:id)
        defer {
            if let previous { defaults.setPersistentDomain(previous,forName:id) }
            else { defaults.removePersistentDomain(forName:id) }
            defaults.synchronize()
        }
        // Simulate the previous release's persisted opt-in, not just new-install defaults.
        defaults.set(true,forKey:"SUAutomaticallyUpdate")
        defaults.set(true,forKey:"SUEnableAutomaticChecks")
        defaults.synchronize()
        precondition(bundle.object(forInfoDictionaryKey:"SUAllowsAutomaticUpdates") as? Bool == false)
        precondition(bundle.object(forInfoDictionaryKey:"SUAutomaticallyUpdate") as? Bool == false)
        let driver = SPUStandardUserDriver(hostBundle:bundle,delegate:nil)
        let updater = SPUUpdater(hostBundle:bundle,applicationBundle:bundle,userDriver:driver,delegate:nil)
        precondition(updater.automaticallyChecksForUpdates)
        precondition(!updater.allowsAutomaticUpdates)
        precondition(!updater.automaticallyDownloadsUpdates,"Persisted automatic-install preference must be overridden")
        print("PASS: automatic checks retained; silent download/install disabled even with legacy preferences")
    }
}
