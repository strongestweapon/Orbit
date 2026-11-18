import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class OrbitUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var status = "업데이트 준비"
    @Published private(set) var detail = "앱을 실행할 때마다 새 버전을 확인합니다."
    @Published private(set) var canCheck = false
    @Published private(set) var isBlocked = false
    @Published private(set) var installing = false
    @Published private(set) var readyVersion: String?
    @Published private(set) var lastChecked: Date?
    private weak var model: OrbitModel?
    private var started = false
    private var subscriptions = Set<AnyCancellable>()
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private lazy var gate = UpdateInstallationGate(isBlocked: { [weak self] in
        guard let self, let model = self.model else { return true }
        return model.outputOpen || model.controlOutputEnabled || model.performance.isRunning
    }, prepare: { [weak self] in self?.prepareInstallation() })

    func startOnce(model: OrbitModel) {
        guard !started else { return }
        started = true
        self.model = model
        model.$outputOpen.combineLatest(model.$controlOutputEnabled, model.performance.$isRunning)
            // @Published sends before storage changes; consume after the model settles.
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.operationChanged() }.store(in: &subscriptions)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheck = $0 }.store(in: &subscriptions)
        do {
            try controller.updater.start()
            if controller.updater.automaticallyChecksForUpdates {
                // Sparkle explicitly supports this immediate, once-per-launch check.
                controller.updater.checkForUpdatesInBackground()
            } else {
                status = "자동 확인 꺼짐"
                detail = "업데이트 메뉴에서 직접 확인할 수 있습니다."
            }
        } catch { report(error) }
    }

    func checkForUpdates() {
        guard canCheck, !isBlocked, !installing else { return }
        controller.checkForUpdates(nil)
    }

    func installIfReady() { gate.resumeIfSafe() }

    private func operationChanged() {
        guard let model else { return }
        isBlocked = model.outputOpen || model.controlOutputEnabled || model.performance.isRunning
        if gate.hasPendingInstallation {
            status = isBlocked ? "업데이트 설치 대기" : "업데이트 설치 준비"
            detail = isBlocked ? "영상 출력·제어 송신·성능 측정이 끝나면 자동으로 설치하고 재시작합니다." : "새 버전을 설치하고 Orbit을 다시 실행합니다."
            gate.resumeIfSafe()
        }
    }

    private func prepareInstallation() {
        model?.updateInstallationInProgress = true
        model?.save()
        installing = true
        status = "업데이트 설치 중"
        detail = "설정과 센서 매핑을 보존하고 새 버전으로 다시 실행합니다."
    }

    private func report(_ error: Error) {
        gate.cancel()
        readyVersion = nil
        installing = false
        model?.updateInstallationInProgress = false
        status = "업데이트 확인 실패"
        detail = error.localizedDescription + " 기존 버전은 계속 사용할 수 있습니다."
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        status = "업데이트 확인 중"
        detail = "GitHub에서 새 버전을 확인합니다."
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "새 버전 \(item.displayVersionString)"
        detail = "새 버전을 다운로드합니다."
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        status = "업데이트 다운로드 중"
        detail = "Orbit \(item.displayVersionString)을 다운로드합니다."
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        status = "업데이트 검증 중"
        detail = "서명을 확인하고 설치를 준비합니다."
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        readyVersion = item.displayVersionString
        gate.schedule(immediateInstallHandler)
        operationChanged()
        return true
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Also covers manual installation and output started during a download.
        if let model, model.outputOpen || model.controlOutputEnabled || model.performance.isRunning {
            readyVersion = item.displayVersionString
            gate.schedule(installHandler)
            operationChanged()
            return true
        }
        prepareInstallation()
        return false
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { model?.save() }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        lastChecked = Date()
        status = "새 업데이트 없음"
        detail = "현재 Mac에 설치할 수 있는 새 업데이트가 없습니다. 다음 실행 때 다시 확인합니다."
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        lastChecked = Date()
        if let error {
            let nsError = error as NSError
            if nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue { return }
            report(error)
        } else if readyVersion == nil && !installing {
            status = "업데이트 확인 완료"
            detail = "다음 실행 때 다시 확인합니다."
        }
    }
}

struct OrbitUpdateMenu: View {
    @EnvironmentObject var updater: OrbitUpdater
    var body: some View {
        Menu {
            Text(updater.status)
            Text(updater.detail)
            if let date = updater.lastChecked { Text("마지막 확인: " + date.formatted(date: .abbreviated, time: .shortened)) }
            Divider()
            Button("업데이트 확인…") { updater.checkForUpdates() }
                .disabled(!updater.canCheck || updater.isBlocked || updater.installing)
            if let version = updater.readyVersion {
                Button("\(version) 설치 및 재시작") { updater.installIfReady() }
                    .disabled(updater.isBlocked || updater.installing)
            }
            Link("GitHub 릴리스 보기", destination: URL(string: "https://github.com/strongestweapon/Orbit/releases")!)
        } label: {
            Label(updater.status, systemImage: "arrow.down.circle")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(updater.detail).accessibilityIdentifier("orbitUpdateStatus")
    }
}
