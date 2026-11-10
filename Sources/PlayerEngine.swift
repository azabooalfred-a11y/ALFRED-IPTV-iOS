import SwiftUI
import UIKit
import AVKit
import MobileVLCKit

/// One audio or subtitle choice in the CC menu (id -1 = subtitles off).
struct TrackOption: Identifiable, Hashable {
    let id: Int
    let name: String
}

/// The player. Apple's player (AVPlayer) plays everything it can — that's what makes
/// Picture-in-Picture instant and AirPlay seamless. Anything it can't open (MKV, odd streams)
/// falls back to VLC by itself, which plays .ts, .mkv and the rest.
final class PlayerEngine: NSObject, ObservableObject, VLCMediaPlayerDelegate, AVPictureInPictureControllerDelegate {
    let player = VLCMediaPlayer()
    let av = AVPlayer()
    /// VLC's stop / open can block for seconds on network streams: keep them off the main thread.
    /// Shared by every player (the channel-list preview too), so a stop always finishes
    /// before the next stream opens.
    private static let vlcQueue = DispatchQueue(label: "alfred.vlc", qos: .userInitiated)
    private var queue: DispatchQueue { PlayerEngine.vlcQueue }
    @Published var playing = false
    @Published var buffering = false
    @Published var failed = false
    /// Position and length in milliseconds (movies / episodes).
    @Published var time: Int32 = 0
    @Published var length: Int32 = 0
    /// Picture size of the stream (for the full-screen options).
    @Published var videoSize: CGSize = .zero
    /// true while Apple's player is the one playing.
    @Published var usingAV = false
    @Published var pipActive = false
    /// true while the video is showing on an AirPlay TV.
    @Published var external = false
    /// A short message for the player to show.
    @Published var notice: String?
    private var volume: Int32 = 100
    /// Resume point (0...1) applied once the length is known.
    var pendingFraction: Double = 0
    private var lastURL: URL?
    private var lastLive = true
    /// The user pressed pause (don't auto-resume after AirPlay / audio route changes).
    private var userPaused = false
    /// Live preview in the channel list: VLC only (its picture view is VLC's).
    private let allowAV: Bool
    private var pip: AVPictureInPictureController?
    /// PiP was started with the button: send the app to the iPhone home screen once it's floating.
    private var pipToHome = false
    private var avObs: [NSKeyValueObservation] = []
    private var avTimeObs: Any?
    private var tokens: [NSObjectProtocol] = []
    private var watchdog: DispatchWorkItem?
    /// Links / servers Apple's player couldn't open (go straight to VLC next time).
    /// Remembered between launches, so a channel that showed a black picture goes straight to VLC.
    private static var avBad: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "avBadLinks") ?? [])
    private static var avBadHosts: [String: Int] = [:]
    private var stallWork: DispatchWorkItem?
    private static let vlcOnlyExt: Set<String> = ["mkv", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "vob", "divx", "xvid"]

    /// Settings for the subtitle size (VLC: a smaller number = bigger text).
    static let subSizes: [(name: String, value: Int)] = [("Small", 20), ("Medium", 16), ("Large", 12), ("Extra large", 8)]
    static var subSizeIndex: Int {
        get { UserDefaults.standard.object(forKey: "subSizeIdx") as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "subSizeIdx") }
    }

    init(allowAV: Bool = true) {
        self.allowAV = allowAV
        super.init()
        player.delegate = self
        guard allowAV else { return }
        av.allowsExternalPlayback = true
        av.usesExternalPlaybackWhileExternalScreenIsActive = true
        avObs.append(av.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self, self.usingAV else { return }
                self.playing = p.timeControlStatus == .playing
                self.buffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if self.playing { self.failed = false }
                // Stuck loading for a long time: let VLC take over.
                self.stallWork?.cancel()
                if self.buffering && self.av.currentItem?.status == .readyToPlay {
                    let url = self.lastURL
                    let w = DispatchWorkItem { [weak self] in
                        guard let self, self.usingAV, self.lastURL == url, !self.userPaused,
                              self.av.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
                        self.avFailed(hostWide: false)
                    }
                    self.stallWork = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
                }
            }
        })
        avObs.append(av.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.external = p.isExternalPlaybackActive
                self.keepPlaying()
            }
        })
        avObs.append(av.observe(\.currentItem?.status, options: [.new]) { [weak self] p, _ in
            let st = p.currentItem?.status
            DispatchQueue.main.async {
                guard let self, self.usingAV else { return }
                if st == .readyToPlay { self.avReady() }
                if st == .failed { self.avFailed(hostWide: true) }
            }
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
        let nc = NotificationCenter.default
        // Picking an AirPlay TV (or unplugging headphones) can pause playback: start it again.
        tokens.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.keepPlaying()
        })
        tokens.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.keepPlaying() }
        })
        tokens.append(nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as? AVPlayerItem) === self.av.currentItem else { return }
            self.avFailed(hostWide: false)
        })
    }

    deinit {
        if let avTimeObs { av.removeTimeObserver(avTimeObs) }
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: play / stop

    func play(_ url: URL?, live: Bool = true) {
        lastURL = url
        lastLive = live
        userPaused = false
        watchdog?.cancel()
        guard let url else {
            failed = true
            return
        }
        failed = false
        buffering = true
        time = 0
        length = 0
        if canUseAV(url) {
            playAV(url)
        } else {
            if usingAV { dropAV() }
            playVLC(url, live: live)
        }
    }

    private func canUseAV(_ url: URL) -> Bool {
        guard allowAV else { return false }
        if PlayerEngine.vlcOnlyExt.contains(url.pathExtension.lowercased()) { return false }
        if url.path.contains("/timeshift/") { return false }
        if PlayerEngine.avBad.contains(url.absoluteString) { return false }
        if lastLive, let h = url.host, (PlayerEngine.avBadHosts[h] ?? 0) >= 2 { return false }
        return true
    }

    /// Xtream live links in TS can't open in Apple's player; the same channel is offered as .m3u8.
    private func avURL(_ u: URL) -> URL {
        guard lastLive, u.pathExtension.lowercased() == "ts", u.path.contains("/live/") else { return u }
        return u.deletingPathExtension().appendingPathExtension("m3u8")
    }

    private func playAV(_ url: URL) {
        let wasAV = usingAV
        usingAV = true
        activateAudio()
        if wasAV {
            openAV(url)
            return
        }
        // One connection at a time: every VLC player (the preview too) lets go of its stream first.
        let p = player
        queue.async {
            if p.media != nil { p.stop() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.usingAV, self.lastURL == url else { return }
                self.openAV(url)
            }
        }
    }

    private func openAV(_ url: URL) {
        let item = AVPlayerItem(url: avURL(url))
        if lastLive { item.preferredForwardBufferDuration = 4 }
        av.volume = Float(volume) / 100
        av.replaceCurrentItem(with: item)
        av.play()
        // Check that a real picture is showing. Apple's player plays the sound of some channels
        // (HEVC / MPEG-2 video) with a black picture: those go to VLC.
        checkPicture(url, after: 4, tries: 3)
    }

    private func checkPicture(_ url: URL, after delay: Double, tries: Int) {
        watchdog?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.usingAV, self.lastURL == url, !self.external else { return }
            let item = self.av.currentItem
            if item?.status != .readyToPlay {
                if tries > 1 { self.checkPicture(url, after: 2, tries: tries - 1) } else { self.avFailed(hostWide: true) }
                return
            }
            let hasPicture = (item?.presentationSize.width ?? 0) > 0
            if hasPicture { return }
            if tries > 1 && self.av.timeControlStatus != .playing {
                self.checkPicture(url, after: 2, tries: tries - 1)
            } else {
                self.avFailed(hostWide: false)
            }
        }
        watchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func avReady() {
        failed = false
        if pendingFraction > 0, let d = av.currentItem?.duration.seconds, d.isFinite, d > 0 {
            av.seek(to: CMTime(seconds: d * pendingFraction, preferredTimescale: 600))
            pendingFraction = 0
        }
        if !userPaused { av.play() }
    }

    /// Apple's player couldn't play this one: VLC carries on from the same spot.
    private func avFailed(hostWide: Bool) {
        watchdog?.cancel()
        stallWork?.cancel()
        guard usingAV, let url = lastURL else { return }
        PlayerEngine.avBad.insert(url.absoluteString)
        UserDefaults.standard.set(Array(PlayerEngine.avBad.prefix(3000)), forKey: "avBadLinks")
        if hostWide, lastLive, let h = url.host { PlayerEngine.avBadHosts[h, default: 0] += 1 }
        let t = av.currentTime().seconds
        let d = av.currentItem?.duration.seconds ?? 0
        if !lastLive, t.isFinite, t > 1, d.isFinite, d > 0 { pendingFraction = t / d }
        if pipActive { pip?.stopPictureInPicture() }
        dropAV()
        if external { notice = "This channel can only send sound to AirPlay" }
        buffering = true
        activateAudio()
        playVLC(url, live: lastLive)
    }

    private func dropAV() {
        av.pause()
        av.replaceCurrentItem(with: nil)
        usingAV = false
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
        userPaused = true
        watchdog?.cancel()
        if pipActive { pip?.stopPictureInPicture() }
        dropAV()
        let p = player
        queue.async {
            if p.media != nil { p.stop() }
        }
    }

    func toggle() {
        if usingAV {
            if av.timeControlStatus == .paused {
                userPaused = false
                av.play()
            } else {
                userPaused = true
                av.pause()
            }
            return
        }
        if player.isPlaying {
            userPaused = true
            player.pause()
        } else {
            userPaused = false
            player.play()
        }
    }

    /// After an AirPlay / audio route change, carry on playing (unless the user paused).
    private func keepPlaying() {
        guard lastURL != nil, !userPaused else { return }
        activateAudio()
        for delay in [0.4, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.userPaused, self.lastURL != nil else { return }
                if self.usingAV {
                    if self.av.timeControlStatus == .paused { self.av.play() }
                } else if self.player.media != nil, !self.player.isPlaying,
                          self.player.state == .paused || self.player.state == .stopped {
                    self.player.play()
                }
            }
        }
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

    /// VLC can switch the audio session off when it stops; Apple's player, PiP and AirPlay need it on.
    private func activateAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    // MARK: AirPlay

    /// AirPlay TV picked: Apple's player sends the picture by itself. VLC can only send sound.
    func airPlayChanged(_ on: Bool) {
        if on && !usingAV && lastURL != nil {
            notice = "This channel can only send sound to AirPlay"
        }
        keepPlaying()
    }

    // MARK: Picture-in-Picture

    var pipSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attachPiP(_ layer: AVPlayerLayer) {
        guard pip == nil, pipSupported else { return }
        let c = AVPictureInPictureController(playerLayer: layer)
        c?.delegate = self
        c?.canStartPictureInPictureAutomaticallyFromInline = true
        pip = c
    }

    /// PiP button: the video floats straight away and the app goes to the iPhone home screen.
    func startPiP() {
        guard let pip else {
            notice = "Picture-in-Picture isn't available on this device"
            return
        }
        guard usingAV else {
            notice = "This channel can't play in Picture-in-Picture"
            return
        }
        pipToHome = true
        if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
            return
        }
        // Still opening: start the moment it's ready (normally well under a second).
        var tries = 0
        func retry() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.pipToHome, !self.pipActive else { return }
                if pip.isPictureInPicturePossible {
                    pip.startPictureInPicture()
                } else if tries < 60 {
                    tries += 1
                    retry()
                } else {
                    self.pipToHome = false
                    self.notice = "Picture-in-Picture couldn't start. Try again in a moment"
                }
            }
        }
        retry()
    }

    func stopPiP() {
        pipToHome = false
        pip?.stopPictureInPicture()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.pipActive = true
            guard self.pipToHome else { return }
            self.pipToHome = false
            // Go to the iPhone home screen, leaving only the floating video.
            let sel = NSSelectorFromString("suspend")
            if UIApplication.shared.responds(to: sel) { _ = UIApplication.shared.perform(sel) }
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.pipActive = false
            if !self.userPaused { self.av.play() }
            self.keepPlaying()
        }
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async {
            self.pipActive = false
            self.pipToHome = false
            self.notice = "Picture-in-Picture couldn't start: " + error.localizedDescription
        }
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        // Back to full screen: keep the video running so the picture comes straight back.
        DispatchQueue.main.async {
            if !self.userPaused { self.av.play() }
            done(true)
        }
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
