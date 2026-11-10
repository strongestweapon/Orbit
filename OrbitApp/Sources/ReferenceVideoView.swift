import SwiftUI
import AVKit

// Original full-frame comparison monitor. The output renderer uses separately extracted strip textures or equations.
// The shared scene clock remains the master; the comparison follows its position and speed.
final class ComparisonPlayback {
    let player = AVPlayer()
    private var sceneID: String?
    private var seeking = false
    private var forceSeek = true
    private var generation = 0
    private var desiredRate: Float = 0
    private var lastCheck: CFTimeInterval = 0

    func invalidatePosition() { forceSeek = true }

    func sync(scene: SceneDescriptor, seconds: Double, playing: Bool, speed: Float) {
        guard let range = scene.referenceSeconds, range.count == 2 else { return }
        if sceneID != scene.id {
            player.pause()
            generation += 1; seeking = false; forceSeek = true
            guard let url = Bundle.main.url(forResource: "KakaoTalk_Video_2026-11-10-09-37-08", withExtension: "mp4") else { return }
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = false
            sceneID = scene.id
        }
        desiredRate = playing ? max(0, speed) : 0
        let now = CACurrentMediaTime()
        let start = range[0] + 1
        let target = start + seconds
        let drift = abs(player.currentTime().seconds - target)
        // Never repeatedly seek a player that is already seeking; completion uses the newest rate.
        if !seeking && (forceSeek || (now - lastCheck > 0.25 && drift > 0.12)) {
            seeking = true; forceSeek = false; lastCheck = now
            let token = generation
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.seeking = false
                    self.player.rate = self.desiredRate
                }
            }
        } else if !seeking && player.rate != desiredRate {
            player.rate = desiredRate
        }
    }
    func stop() {
        generation += 1; player.pause(); player.replaceCurrentItem(with: nil)
        sceneID = nil; seeking = false; forceSeek = true; desiredRate = 0
    }
}

struct ReferenceVideoView: NSViewRepresentable {
    let playback: ComparisonPlayback
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = playback.player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
