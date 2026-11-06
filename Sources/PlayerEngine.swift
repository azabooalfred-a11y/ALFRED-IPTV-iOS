import SwiftUI
import UIKit
import MobileVLCKit

/// VLC player (plays .ts, .m3u8, .mkv and the rest).
final class PlayerEngine: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    @Published var playing = false
    @Published var buffering = false
    @Published var failed = false
    private var volume: Int32 = 100

    override init() {
        super.init()
        player.delegate = self
    }

    func play(_ url: URL?) {
        guard let url else {
            failed = true
            return
        }
        failed = false
        buffering = true
        let media = VLCMedia(url: url)
        media.addOptions([
            "network-caching": 1500,
            "http-user-agent": Xtream.userAgent,
            "http-reconnect": true,
        ])
        player.media = media
        player.play()
    }

    func stop() {
        if player.media != nil { player.stop() }
        playing = false
        buffering = false
    }

    func toggle() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func setVolume(_ v: Int) {
        volume = Int32(max(0, min(100, v)))
        player.audio?.volume = volume
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch self.player.state {
            case .opening, .buffering:
                if !self.player.isPlaying { self.buffering = true }
            case .playing:
                self.buffering = false
                self.player.audio?.volume = self.volume
            case .error:
                self.failed = true
                self.buffering = false
            case .ended, .stopped:
                self.buffering = false
            default:
                break
            }
            self.playing = self.player.isPlaying
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.buffering else { return }
            self.buffering = false
            self.playing = true
            self.player.audio?.volume = self.volume
        }
    }
}

struct VLCVideoView: UIViewRepresentable {
    let engine: PlayerEngine

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        engine.player.drawable = v
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
