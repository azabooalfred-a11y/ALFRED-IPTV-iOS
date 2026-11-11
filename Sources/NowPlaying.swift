import UIKit
import MediaPlayer

/// Lock Screen & Control Center player — sample 13A: channel name, what's on, pause,
/// and ⏮ ⏭ to change channel without unlocking.
final class NowPlaying {
    static let shared = NowPlaying()

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onSkip: ((Double) -> Void)?

    private var artURL = ""
    private var art: MPMediaItemArtwork?
    private var artTask: URLSessionDataTask?

    private var commands: [MPRemoteCommand] {
        let c = MPRemoteCommandCenter.shared()
        return [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.nextTrackCommand,
                c.previousTrackCommand, c.skipForwardCommand, c.skipBackwardCommand]
    }

    /// next = ⏮ ⏭ change channel / episode; skip = ±10 s buttons (movies).
    func start(next: Bool, skip: Bool) {
        removeTargets()
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.onPlay?(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.onPause?(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.onToggle?(); return .success }
        c.nextTrackCommand.isEnabled = next
        c.previousTrackCommand.isEnabled = next
        if next {
            c.nextTrackCommand.addTarget { [weak self] _ in self?.onNext?(); return .success }
            c.previousTrackCommand.addTarget { [weak self] _ in self?.onPrev?(); return .success }
        }
        c.skipForwardCommand.isEnabled = skip && !next
        c.skipBackwardCommand.isEnabled = skip && !next
        if skip && !next {
            c.skipForwardCommand.preferredIntervals = [10]
            c.skipBackwardCommand.preferredIntervals = [10]
            c.skipForwardCommand.addTarget { [weak self] _ in self?.onSkip?(10); return .success }
            c.skipBackwardCommand.addTarget { [weak self] _ in self?.onSkip?(-10); return .success }
        }
        c.changePlaybackPositionCommand.isEnabled = false
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    func stop() {
        removeTargets()
        artTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UIApplication.shared.endReceivingRemoteControlEvents()
    }

    private func removeTargets() {
        for cmd in commands { cmd.removeTarget(nil) }
    }

    func update(title: String, subtitle: String, live: Bool, playing: Bool,
                elapsed: Double, duration: Double, artwork: String) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: subtitle,
            MPMediaItemPropertyAlbumTitle: "ALFRED-IPTV",
            MPNowPlayingInfoPropertyIsLiveStream: live,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if !live && duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed)
        }
        if artwork != artURL {
            artURL = artwork
            art = NowPlaying.logoArt
            loadArt(artwork)
        }
        if let art { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private static var logoArt: MPMediaItemArtwork? {
        guard let img = UIImage(named: "Logo") else { return nil }
        return MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    /// Channel logo / poster as the Lock Screen picture (app logo until it loads).
    private func loadArt(_ link: String) {
        artTask?.cancel()
        guard let url = URL(string: link), !link.isEmpty else { return }
        let t = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.artURL == link else { return }
                let a = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                self.art = a
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                if info.isEmpty { return }
                info[MPMediaItemPropertyArtwork] = a
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
        artTask = t
        t.resume()
    }
}
