import SwiftUI
import UIKit
import MobileVLCKit

/// VLC player (plays .ts, .m3u8, .mkv and the rest).
final class PlayerEngine: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    /// VLC's stop / open can block for seconds on network streams: keep them off the main thread.
    private let queue = DispatchQueue(label: "alfred.vlc", qos: .userInitiated)
    @Published var playing = false
    @Published var buffering = false
    @Published var failed = false
    /// Position and length in milliseconds (movies / episodes).
    @Published var time: Int32 = 0
    @Published var length: Int32 = 0
    /// Picture size of the stream (for the full-screen options).
    @Published var videoSize: CGSize = .zero
    private var volume: Int32 = 100
    /// Resume point (0...1) applied once the length is known.
    var pendingFraction: Double = 0

    override init() {
        super.init()
        player.delegate = self
    }

    func play(_ url: URL?, live: Bool = true) {
        guard let url else {
            failed = true
            return
        }
        failed = false
        buffering = true
        time = 0
        length = 0
        let media = VLCMedia(url: url)
        media.addOptions([
            "network-caching": live ? 1000 : 600,
            "http-user-agent": Xtream.userAgent,
            "http-reconnect": true,
            "avcodec-hw": "any",
        ])
        let p = player
        queue.async {
            if p.media != nil { p.stop() }
            p.media = media
            p.play()
        }
    }

    func stop() {
        playing = false
        buffering = false
        let p = player
        queue.async {
            if p.media != nil { p.stop() }
        }
    }

    func toggle() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func seek(_ fraction: Double) {
        player.position = Float(max(0, min(1, fraction)))
    }

    func jump(_ seconds: Int32) {
        if seconds >= 0 { player.jumpForward(seconds) } else { player.jumpBackward(-seconds) }
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
            guard let self else { return }
            self.time = self.player.time.intValue
            let len = self.player.media?.length.intValue ?? 0
            if len != self.length { self.length = len }
            if self.pendingFraction > 0, len > 0 {
                self.player.position = Float(self.pendingFraction)
                self.pendingFraction = 0
            }
            let vs = self.player.videoSize
            if vs.width > 0, vs != self.videoSize { self.videoSize = vs }
            guard self.buffering else { return }
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
        v.isUserInteractionEnabled = false   // taps go to the SwiftUI view on top (preview → full screen)
        engine.player.drawable = v
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
