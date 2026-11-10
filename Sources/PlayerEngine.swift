import SwiftUI
import UIKit
import AVKit
import MobileVLCKit

/// One audio or subtitle choice in the CC menu (id -1 = subtitles off).
struct TrackOption: Identifiable, Hashable {
    let id: Int
    let name: String
}

/// VLC player (plays .ts, .m3u8, .mkv and the rest).
/// Picture-in-Picture and AirPlay video only work with Apple's player, so for those the same
/// stream is handed over to an AVPlayer and handed back to VLC afterwards.
final class PlayerEngine: NSObject, ObservableObject, VLCMediaPlayerDelegate, AVPictureInPictureControllerDelegate {
    let player = VLCMediaPlayer()
    /// Apple player, used for Picture-in-Picture and AirPlay.
    let av = AVPlayer()
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
    /// true while the Apple player is playing (Picture-in-Picture / AirPlay).
    @Published var usingAV = false
    @Published var pipActive = false
    /// true while the video is showing on an AirPlay TV.
    @Published var external = false
    private var volume: Int32 = 100
    /// Resume point (0...1) applied once the length is known.
    var pendingFraction: Double = 0
    private var lastURL: URL?
    private var lastLive = true
    private var pip: AVPictureInPictureController?
    private var avObs: [NSKeyValueObservation] = []
    private var avTimeObs: Any?

    /// Settings for the subtitle size (VLC: a smaller number = bigger text).
    static let subSizes: [(name: String, value: Int)] = [("Small", 20), ("Medium", 16), ("Large", 12), ("Extra large", 8)]
    static var subSizeIndex: Int {
        get { UserDefaults.standard.object(forKey: "subSizeIdx") as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "subSizeIdx") }
    }

    override init() {
        super.init()
        player.delegate = self
        av.allowsExternalPlayback = true
        av.usesExternalPlaybackWhileExternalScreenIsActive = true
        avObs.append(av.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self, self.usingAV else { return }
                self.playing = p.timeControlStatus == .playing
                self.buffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        })
        avObs.append(av.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async { self?.external = p.isExternalPlaybackActive }
        })
        avTimeObs = av.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                               queue: .main) { [weak self] t in
            guard let self, self.usingAV, let item = self.av.currentItem else { return }
            let s = t.seconds
            if s.isFinite { self.time = Int32(max(0, s) * 1000) }
            let d = item.duration.seconds
            let len: Int32 = d.isFinite && d > 0 ? Int32(d * 1000) : 0
            if len != self.length { self.length = len }
            let vs = item.presentationSize
            if vs.width > 0, vs != self.videoSize { self.videoSize = vs }
        }
    }

    deinit {
        if let avTimeObs { av.removeTimeObserver(avTimeObs) }
    }

    func play(_ url: URL?, live: Bool = true) {
        lastURL = url
        lastLive = live
        guard let url else {
            failed = true
            return
        }
        failed = false
        buffering = true
        time = 0
        length = 0
        if usingAV {
            // Already on AirPlay / Picture-in-Picture: keep the new channel there too.
            Task {
                let ok = await self.startAV()
                if !ok {
                    await MainActor.run {
                        self.dropAV()
                        self.playVLC(url, live: live)
                    }
                }
            }
            return
        }
        playVLC(url, live: live)
    }

    private func playVLC(_ url: URL, live: Bool) {
        let media = VLCMedia(url: url)
        media.addOptions([
            "network-caching": live ? 1000 : 600,
            "http-user-agent": Xtream.userAgent,
            "http-reconnect": true,
            "avcodec-hw": "any",
            "freetype-rel-fontsize": PlayerEngine.subSizes[PlayerEngine.subSizeIndex].value,
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
        pip?.stopPictureInPicture()
        dropAV()
        let p = player
        queue.async {
            if p.media != nil { p.stop() }
        }
    }

    func toggle() {
        if usingAV {
            if av.timeControlStatus == .paused { av.play() } else { av.pause() }
            return
        }
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func seek(_ fraction: Double) {
        let f = max(0, min(1, fraction))
        if usingAV {
            if let d = av.currentItem?.duration.seconds, d.isFinite, d > 0 {
                av.seek(to: CMTime(seconds: d * f, preferredTimescale: 600))
            }
            return
        }
        player.position = Float(f)
    }

    func jump(_ seconds: Int32) {
        if usingAV {
            let t = av.currentTime().seconds + Double(seconds)
            av.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600))
            return
        }
        if seconds >= 0 { player.jumpForward(seconds) } else { player.jumpBackward(-seconds) }
    }

    func setVolume(_ v: Int) {
        volume = Int32(max(0, min(100, v)))
        player.audio?.volume = volume
        av.volume = Float(volume) / 100
    }

    // MARK: Apple player (Picture-in-Picture / AirPlay)

    /// Xtream live links in TS can't open in Apple's player; the same channel is offered as .m3u8.
    private func avURL(_ u: URL) -> URL {
        guard lastLive, u.pathExtension.lowercased() == "ts", u.path.contains("/live/") else { return u }
        return u.deletingPathExtension().appendingPathExtension("m3u8")
    }

    /// Moves playback to the Apple player at the same spot. false when this stream can't play there.
    func startAV() async -> Bool {
        guard let url = lastURL else { return false }
        let wasAV = usingAV
        let resumeMs = (!lastLive && !wasAV) ? Double(time) : 0
        let asset = AVURLAsset(url: avURL(url), options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": Xtream.userAgent]])
        let item = AVPlayerItem(asset: asset)
        av.replaceCurrentItem(with: item)
        var waited = 0
        while item.status == .unknown && waited < 60 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 1
        }
        guard item.status == .readyToPlay else {
            if !wasAV { av.replaceCurrentItem(with: nil) }
            return false
        }
        var target = resumeMs / 1000
        let d = item.duration.seconds
        if target <= 1, pendingFraction > 0, d.isFinite, d > 0 {
            target = d * pendingFraction
        }
        if target > 1 {
            _ = await av.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        }
        await MainActor.run {
            if !self.usingAV {
                let p = self.player
                self.queue.async { if p.media != nil { p.stop() } }
            }
            self.pendingFraction = 0
            self.usingAV = true
            self.failed = false
            self.buffering = false
            self.av.volume = Float(self.volume) / 100
            self.av.play()
        }
        return true
    }

    /// Back to VLC (after Picture-in-Picture or AirPlay ends) at the same spot.
    func leaveAV() {
        guard usingAV else { return }
        let t = av.currentTime().seconds
        let d = av.currentItem?.duration.seconds ?? 0
        dropAV()
        guard let url = lastURL else { return }
        if !lastLive, t.isFinite, d.isFinite, d > 0 { pendingFraction = t / d }
        buffering = true
        playVLC(url, live: lastLive)
    }

    private func dropAV() {
        av.pause()
        av.replaceCurrentItem(with: nil)
        usingAV = false
        external = false
    }

    var pipSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attachPiP(_ layer: AVPlayerLayer) {
        guard pip == nil, pipSupported else { return }
        let c = AVPictureInPictureController(playerLayer: layer)
        c?.delegate = self
        c?.canStartPictureInPictureAutomaticallyFromInline = false
        pip = c
    }

    /// Picture-in-Picture button. false when this stream can't play in Picture-in-Picture.
    func startPiP() async -> Bool {
        if !usingAV {
            guard await startAV() else { return false }
        }
        guard let pip else { return false }
        var waited = 0
        while !pip.isPictureInPicturePossible && waited < 25 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 1
        }
        guard pip.isPictureInPicturePossible else { return false }
        await MainActor.run { pip.startPictureInPicture() }
        return true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.pipActive = true }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.pipActive = false
            if !self.external { self.leaveAV() }
        }
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async { self.pipActive = false }
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        done(true)
    }

    // MARK: audio & subtitles (CC menu)

    func audioTracks() -> (list: [TrackOption], current: Int) {
        if usingAV { return avOptions(.audible, off: false) }
        let names = (player.audioTrackNames ?? []).map { "\($0)" }
        let ids = (player.audioTrackIndexes ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        let list = zip(ids, names).filter { $0.0 >= 0 }.map { TrackOption(id: $0.0, name: $0.1) }
        return (list, Int(player.currentAudioTrackIndex))
    }

    func subtitleTracks() -> (list: [TrackOption], current: Int) {
        if usingAV { return avOptions(.legible, off: true) }
        let names = (player.videoSubTitlesNames ?? []).map { "\($0)" }
        let ids = (player.videoSubTitlesIndexes ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        var list = zip(ids, names).filter { $0.0 >= 0 }.map { TrackOption(id: $0.0, name: $0.1) }
        list.insert(TrackOption(id: -1, name: "Off"), at: 0)
        let cur = Int(player.currentVideoSubTitleIndex)
        return (list, cur < 0 ? -1 : cur)
    }

    func setAudio(_ id: Int) {
        if usingAV { selectAV(.audible, id) } else { player.currentAudioTrackIndex = Int32(id) }
    }

    func setSubtitle(_ id: Int) {
        if usingAV { selectAV(.legible, id) } else { player.currentVideoSubTitleIndex = Int32(id) }
    }

    /// Subtitle delay in seconds (+ = later).
    var subDelay: Double {
        get { Double(player.currentVideoSubTitleDelay) / 1_000_000 }
        set { player.currentVideoSubTitleDelay = Int(newValue * 1_000_000) }
    }

    func setSubSize(_ i: Int) {
        guard PlayerEngine.subSizes.indices.contains(i) else { return }
        PlayerEngine.subSizeIndex = i
        applySubSize()
    }

    private func applySubSize() {
        let sel = NSSelectorFromString("setTextRendererFontSize:")
        if player.responds(to: sel) {
            _ = player.perform(sel, with: NSNumber(value: PlayerEngine.subSizes[PlayerEngine.subSizeIndex].value))
        }
    }

    private func avOptions(_ c: AVMediaCharacteristic, off: Bool) -> (list: [TrackOption], current: Int) {
        guard let item = av.currentItem,
              let g = item.asset.mediaSelectionGroup(forMediaCharacteristic: c) else {
            return (off ? [TrackOption(id: -1, name: "Off")] : [], -1)
        }
        var list = g.options.enumerated().map { TrackOption(id: $0.offset, name: $0.element.displayName) }
        if off { list.insert(TrackOption(id: -1, name: "Off"), at: 0) }
        let sel = item.currentMediaSelection.selectedMediaOption(in: g)
        let cur = sel.flatMap { g.options.firstIndex(of: $0) } ?? -1
        return (list, cur)
    }

    private func selectAV(_ c: AVMediaCharacteristic, _ id: Int) {
        guard let item = av.currentItem,
              let g = item.asset.mediaSelectionGroup(forMediaCharacteristic: c) else { return }
        item.select(g.options.indices.contains(id) ? g.options[id] : nil, in: g)
    }

    // MARK: VLC events

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.usingAV else { return }
            switch self.player.state {
            case .opening, .buffering:
                if !self.player.isPlaying { self.buffering = true }
            case .playing:
                self.buffering = false
                self.player.audio?.volume = self.volume
                self.applySubSize()
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
            guard let self, !self.usingAV else { return }
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

/// Apple player picture (shown during Picture-in-Picture / AirPlay hand-over).
final class AVLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct AVVideoView: UIViewRepresentable {
    let engine: PlayerEngine
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> AVLayerUIView {
        let v = AVLayerUIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        v.playerLayer.player = engine.av
        engine.attachPiP(v.playerLayer)
        return v
    }

    func updateUIView(_ v: AVLayerUIView, context: Context) {
        v.playerLayer.videoGravity = gravity
    }
}

/// The system AirPlay button (opens the list of TVs), in the app's round glass style.
struct AirPlayButton: View {
    var size: CGFloat = 44

    var body: some View {
        RoutePicker()
            .frame(width: size * 0.7, height: size * 0.7)
            .frame(width: size, height: size)
            .background(T.glass)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.15)))
    }

    private struct RoutePicker: UIViewRepresentable {
        func makeUIView(context: Context) -> AVRoutePickerView {
            let v = AVRoutePickerView()
            v.tintColor = .white
            v.activeTintColor = UIColor(red: 0x3A / 255, green: 0xD7 / 255, blue: 1, alpha: 1)
            v.prioritizesVideoDevices = true
            return v
        }

        func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
    }
}
