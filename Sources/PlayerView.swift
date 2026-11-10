import SwiftUI
import UIKit
import AVKit
import Combine

/// Something the player can play: a live channel, a movie or an episode.
struct PlayItem: Identifiable {
    let id: String
    let num: Int
    let title: String
    let icon: String
    let url: URL?
    var channel: Channel? = nil
    /// Continue watching key ("movie:id" / "ep:id") and the series it belongs to.
    var resumeKey: String? = nil
    var seriesId: String? = nil
}

struct PlayRequest: Identifiable {
    let id = UUID()
    let items: [PlayItem]
    let index: Int
    let live: Bool
}

/// Full screen player — sample B: floating glass bar, brightness (left) and volume (right) bars.
struct PlayerView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    let list: [PlayItem]
    let live: Bool
    @State private var index: Int
    @StateObject private var engine = PlayerEngine()
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var vol: Double = 1
    @State private var bright: Double = Double(UIScreen.main.brightness)
    @State private var dragStart: Double?
    @State private var showList = false
    @State private var now = ""
    @State private var next = ""
    @State private var wasPortrait = true
    @State private var scrub: Double?
    @State private var showAspect = false
    /// Full-screen option: 0 Fit, 1 Fill screen, 2 Stretch, 3 16:9, 4 4:3 (remembered).
    @AppStorage("aspectMode") private var aspect = 0
    /// CC menu (sample B): 0 main list, 1 audio, 2 subtitles, 3 subtitle size, 4 subtitle delay.
    @State private var showTracks = false
    @State private var trackPage = 0
    @State private var audio: [TrackOption] = []
    @State private var audioCur = -1
    @State private var subs: [TrackOption] = []
    @State private var subCur = -1
    @State private var subDelay = 0.0
    @State private var subSize = PlayerEngine.subSizeIndex
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    /// Name of the AirPlay TV in use ("" = none).
    @State private var tvName = ""
    private static let aspectNames = ["Fit", "Fill screen", "Stretch", "16:9", "4:3"]

    init(request: PlayRequest) {
        list = request.items
        live = request.live
        _index = State(initialValue: request.index)
    }

    private var item: PlayItem { list[index] }

    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.black.ignoresSafeArea()
                let sc = scale(g)
                VLCVideoView(engine: engine)
                    .scaleEffect(x: sc.width, y: sc.height)
                    .ignoresSafeArea()
                    .opacity(engine.usingAV ? 0 : 1)
                // Apple player, for Picture-in-Picture and AirPlay.
                AVVideoView(engine: engine, gravity: avGravity)
                    .ignoresSafeArea()
                    .opacity(engine.usingAV ? 1 : 0.01)
                    .allowsHitTesting(false)

                if engine.external { onTV }

                if engine.buffering && !engine.failed {
                    ProgressView().tint(.white).scaleEffect(1.5)
                }
                if engine.failed {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
                        Text(live ? "This channel isn't working right now." : "This video isn't working right now.")
                        Pill(icon: "arrow.clockwise", title: "Try again") { start() }
                    }
                    .foregroundColor(.white)
                }

                // Tap to show/hide controls; swipe left side = brightness, right side = volume.
                HStack(spacing: 0) {
                    gestureArea(g, volume: false)
                    gestureArea(g, volume: true)
                }
                .ignoresSafeArea()

                if controls { overlay.transition(.opacity) }
                if controls && showTracks { tracksPanel.transition(.opacity) }
                if let toast {
                    VStack {
                        Text(toast)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.top, 70)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                if showList { channelList.transition(.move(edge: .trailing)) }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            wasPortrait = Orientation.isPortrait
            Orientation.lock(.landscape)
            UIApplication.shared.isIdleTimerDisabled = true
            start()
            bumpHide()
            routeChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)) { _ in routeChanged() }
        .onDisappear {
            savePos()
            engine.stop()
            hideTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
            if wasPortrait {
                Orientation.lock(.portrait)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Orientation.unlock() }
            } else {
                Orientation.unlock()
            }
        }
    }

    private func gestureArea(_ g: GeometryProxy, volume: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                if showList { withAnimation { showList = false } } else { toggleControls() }
            }
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        if dragStart == nil {
                            dragStart = volume ? vol : bright
                            hideTask?.cancel()
                            withAnimation { controls = true }
                        }
                        let x = min(1, max(0, (dragStart ?? 0) - Double(v.translation.height / (g.size.height * 0.8))))
                        if volume {
                            vol = x
                            engine.setVolume(Int(x * 100))
                        } else {
                            bright = x
                            UIScreen.main.brightness = CGFloat(x)
                        }
                    }
                    .onEnded { _ in
                        dragStart = nil
                        bumpHide()
                    }
            )
    }

    private var overlay: some View {
        ZStack {
            VStack {
                HStack(spacing: 10) {
                    CircleButton(icon: "chevron.left") { dismiss() }
                    Spacer()
                    CircleButton(icon: "captions.bubble", filled: showTracks) { openTracks() }
                    AirPlayButton()
                    if engine.pipSupported {
                        CircleButton(icon: engine.pipActive ? "pip.exit" : "pip.enter", filled: engine.pipActive) { pipTapped() }
                    }
                }
                Spacer()
            }
            .padding(.top, 16)
            .padding(.horizontal, 24)

            HStack {
                LevelBar(value: bright, icon: "sun.max.fill")
                Spacer()
                LevelBar(value: vol, icon: vol == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .padding(.horizontal, 26)
            .allowsHitTesting(false)

            VStack {
                Spacer()
                bottomBar
            }
            .padding(.leading, 64)
            .padding(.trailing, 76)
            .padding(.bottom, 14)

            aspectButton
        }
    }

    // MARK: full-screen options (sample B)

    private var aspectButton: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Spacer()
            if showAspect {
                VStack(spacing: 2) {
                    ForEach(PlayerView.aspectNames.indices, id: \.self) { i in
                        Button {
                            aspect = i
                            withAnimation { showAspect = false }
                            bumpHide()
                        } label: {
                            HStack {
                                Text(PlayerView.aspectNames[i])
                                Spacer()
                                if i == aspect { Image(systemName: "checkmark") }
                            }
                            .font(.system(size: 14, weight: i == aspect ? .bold : .regular))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(i == aspect ? T.accent : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                .padding(6)
                .frame(width: 180)
                .background(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
            }
            CircleButton(icon: "arrow.up.left.and.arrow.down.right", size: 44, filled: aspect != 0) {
                hideTask?.cancel()
                withAnimation(.easeOut(duration: 0.15)) { showAspect.toggle() }
                if !showAspect { bumpHide() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 16)
        .padding(.bottom, 16)
    }

    /// How much to stretch the picture (VLC draws it "fit" inside the view).
    private func scale(_ g: GeometryProxy) -> CGSize {
        let full = UIScreen.main.bounds.size
        let W = max(full.width, full.height), H = min(full.width, full.height)
        var v = engine.videoSize
        if v.width <= 0 || v.height <= 0 { v = CGSize(width: 16, height: 9) }
        let s = min(W / v.width, H / v.height)
        let fw = v.width * s, fh = v.height * s
        func fitted(_ r: CGFloat) -> CGSize {
            W / H > r ? CGSize(width: H * r, height: H) : CGSize(width: W, height: W / r)
        }
        switch aspect {
        case 1:
            let k = max(W / fw, H / fh)
            return CGSize(width: k, height: k)
        case 2:
            return CGSize(width: W / fw, height: H / fh)
        case 3:
            let t = fitted(16.0 / 9.0)
            return CGSize(width: t.width / fw, height: t.height / fh)
        case 4:
            let t = fitted(4.0 / 3.0)
            return CGSize(width: t.width / fw, height: t.height / fh)
        default:
            return CGSize(width: 1, height: 1)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if !live { seekBar }
            HStack(spacing: 12) {
                LogoImage(url: item.icon).frame(width: 46, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(live ? "\(item.num) · \(item.title)" : item.title)
                        .font(.system(size: 15, weight: .heavy))
                        .lineLimit(1)
                    Text(subLine)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: 0xCFD6FF))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if live {
                        CircleButton(icon: "backward.end.fill", size: 40) { change(-1) }
                    } else {
                        CircleButton(icon: "gobackward.10", size: 40) { engine.jump(-10); bumpHide() }
                    }
                    CircleButton(icon: engine.playing ? "pause.fill" : "play.fill", size: 40, filled: true) {
                        engine.toggle()
                        bumpHide()
                    }
                    if live {
                        CircleButton(icon: "forward.end.fill", size: 40) { change(1) }
                        if let c = item.channel {
                            CircleButton(icon: store.isFav(c) ? "heart.fill" : "heart", size: 40) {
                                store.toggleFav(c)
                                bumpHide()
                            }
                        }
                    } else {
                        CircleButton(icon: "goforward.10", size: 40) { engine.jump(10); bumpHide() }
                        if list.count > 1 && index + 1 < list.count {
                            CircleButton(icon: "forward.end.fill", size: 40) { change(1) }
                        }
                    }
                    if list.count > 1 {
                        CircleButton(icon: "list.bullet", size: 40) {
                            hideTask?.cancel()
                            withAnimation { showList = true; controls = false }
                        }
                    }
                }
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var seekBar: some View {
        let len = Double(engine.length)
        let pos = len > 0 ? Double(engine.time) / len : 0
        return HStack(spacing: 10) {
            Text(PlayerView.clock(scrub.map { $0 * len } ?? Double(engine.time)))
                .font(.system(size: 11).monospacedDigit())
            Slider(value: Binding(get: { scrub ?? pos }, set: { scrub = $0 }), in: 0...1) { editing in
                if editing {
                    hideTask?.cancel()
                } else {
                    if let s = scrub { engine.seek(s) }
                    scrub = nil
                    bumpHide()
                }
            }
            .tint(T.cyan)
            .disabled(len <= 0)
            Text(PlayerView.clock(len))
                .font(.system(size: 11).monospacedDigit())
        }
    }

    static func clock(_ ms: Double) -> String {
        let t = max(0, Int(ms / 1000))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private var subLine: String {
        if !live { return list.count > 1 ? "\(index + 1) of \(list.count)" : "Movie" }
        if now.isEmpty { return "Live" }
        return next.isEmpty ? "Now: \(now)" : "Now: \(now) · Next: \(next)"
    }

    private var channelList: some View {
        HStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Text(live ? "Channels" : "Episodes").font(.system(size: 15, weight: .heavy)).padding(.horizontal, 6)
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 2) {
                            ForEach(list.indices, id: \.self) { i in
                                HStack(spacing: 8) {
                                    Text("\(list[i].num)").font(.system(size: 11)).foregroundColor(Color(hex: 0xCFD6FF))
                                        .frame(width: 30, alignment: .leading)
                                    if live { LogoImage(url: list[i].icon).frame(width: 30, height: 22) }
                                    Text(list[i].title).font(.system(size: 13)).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.vertical, 7).padding(.horizontal, 8)
                                .background(i == index ? T.accent : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                                .id(i)
                                .onTapGesture {
                                    savePos()
                                    index = i
                                    start()
                                }
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(index, anchor: .center) }
                }
            }
            .foregroundColor(.white)
            .padding(.vertical, 14)
            .padding(.horizontal, 10)
            .frame(width: 300)
            .background(.ultraThinMaterial)
        }
        .ignoresSafeArea(edges: .vertical)
    }

    // MARK: actions

    private func savePos() {
        guard !live, let key = item.resumeKey else { return }
        store.savePosition(key, time: Double(engine.time), length: Double(engine.length))
    }

    private func start() {
        engine.setVolume(Int(vol * 100))
        if let key = item.resumeKey {
            let f = store.progress(key)
            engine.pendingFraction = f > 0.01 && f < 0.95 ? f : 0
            if let sid = item.seriesId { store.setLastEpisode(sid, item.id) }
        }
        engine.play(item.url, live: live)
        now = ""
        next = ""
        guard live, let c = item.channel else { return }
        store.addHistory("live", c.id)
        Task {
            guard let api = store.api else { return }
            let p = await EpgCache.shared.programs(api, c)
            if c.id == item.channel?.id {
                now = p.first?.title ?? ""
                next = p.count > 1 ? p[1].title : ""
            }
        }
    }

    private func change(_ step: Int) {
        guard !list.isEmpty else { return }
        savePos()
        index = (index + step + list.count) % list.count
        start()
        bumpHide()
    }

    private func toggleControls() {
        if showTracks {
            withAnimation { showTracks = false }
            bumpHide()
            return
        }
        if showAspect {
            withAnimation { showAspect = false }
            bumpHide()
            return
        }
        if controls {
            hideTask?.cancel()
            withAnimation { controls = false }
        } else {
            bumpHide()
        }
    }

    private func bumpHide() {
        hideTask?.cancel()
        withAnimation { controls = true }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled && !showList && scrub == nil && !showAspect && !showTracks {
                withAnimation { controls = false }
            }
        }
    }
}

// MARK: Picture-in-Picture, AirPlay, audio & subtitles

extension PlayerView {
    private var avGravity: AVLayerVideoGravity {
        switch aspect {
        case 1: return .resizeAspectFill
        case 2: return .resize
        default: return .resizeAspect
        }
    }

    /// Shown on the phone while the video plays on the AirPlay TV.
    private var onTV: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 10) {
                Image(systemName: "airplayvideo")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 76, height: 76)
                    .background(LinearGradient(colors: T.live, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(Circle())
                Text(tvName.isEmpty ? "Playing on your TV" : "Playing on \(tvName)")
                    .font(.system(size: 18, weight: .black))
                Text(item.title).font(.system(size: 13)).foregroundColor(T.dim)
            }
            .foregroundColor(.white)
        }
        .allowsHitTesting(false)
    }

    private func pipTapped() {
        if engine.pipActive {
            engine.leaveAV()
            return
        }
        showToast("Starting Picture-in-Picture…")
        Task {
            let ok = await engine.startPiP()
            await MainActor.run {
                if !ok { showToast("This stream can't play in Picture-in-Picture") }
            }
        }
    }

    /// AirPlay TV picked / dropped: video goes through Apple's player while a TV is in use.
    private func routeChanged() {
        let tv = AVAudioSession.sharedInstance().currentRoute.outputs.first { $0.portType == .airPlay }
        tvName = tv?.portName ?? ""
        if tv != nil {
            guard !engine.usingAV else { return }
            Task {
                let ok = await engine.startAV()
                await MainActor.run {
                    if !ok { showToast("This stream can only send sound to AirPlay") }
                }
            }
        } else if engine.usingAV && !engine.pipActive {
            engine.leaveAV()
        }
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation { toast = text }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { withAnimation { toast = nil } }
        }
    }

    private func refreshTracks() {
        let a = engine.audioTracks()
        audio = a.list
        audioCur = a.current
        let s = engine.subtitleTracks()
        subs = s.list
        subCur = s.current
        subDelay = engine.subDelay
        subSize = PlayerEngine.subSizeIndex
    }

    private func openTracks() {
        hideTask?.cancel()
        showAspect = false
        refreshTracks()
        trackPage = 0
        withAnimation(.easeOut(duration: 0.15)) { showTracks.toggle() }
        if !showTracks { bumpHide() }
    }

    private func name(_ list: [TrackOption], _ id: Int, _ none: String) -> String {
        list.first { $0.id == id }?.name ?? none
    }

    /// CC menu — sample B: Audio, Subtitles, Subtitle size, Subtitle delay.
    private var tracksPanel: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    switch trackPage {
                    case 1:
                        pageTitle("Audio")
                        trackList(audio, audioCur, empty: "Only one audio track") { id in
                            engine.setAudio(id)
                            audioCur = id
                        }
                    case 2:
                        pageTitle("Subtitles")
                        trackList(subs, subCur, empty: "No subtitles in this video") { id in
                            engine.setSubtitle(id)
                            subCur = id
                        }
                    case 3:
                        pageTitle("Subtitle size")
                        trackList(PlayerEngine.subSizes.indices.map { TrackOption(id: $0, name: PlayerEngine.subSizes[$0].name) },
                                  subSize, empty: "") { id in
                            engine.setSubSize(id)
                            subSize = id
                        }
                    case 4:
                        pageTitle("Subtitle delay")
                        HStack(spacing: 14) {
                            CircleButton(icon: "minus", size: 38) { setDelay(subDelay - 0.5) }
                            Text(String(format: "%+.1fs", subDelay))
                                .font(.system(size: 17, weight: .heavy).monospacedDigit())
                                .frame(minWidth: 70)
                            CircleButton(icon: "plus", size: 38) { setDelay(subDelay + 0.5) }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        menuRow("Reset to 0.0s", "", on: false) { setDelay(0) }
                    default:
                        menuRow("Audio", name(audio, audioCur, "Default"), on: false) { trackPage = 1 }
                        menuRow("Subtitles", name(subs, subCur, "Off"), on: subCur >= 0) { trackPage = 2 }
                        if !engine.usingAV {
                            menuRow("Subtitle size", PlayerEngine.subSizes[subSize].name, on: false) { trackPage = 3 }
                            menuRow("Subtitle delay", String(format: "%.1fs", subDelay), on: false) { trackPage = 4 }
                        }
                    }
                }
                .foregroundColor(.white)
                .padding(6)
                .frame(width: 250)
                .background(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Spacer()
        }
        .padding(.top, 70)
        .padding(.trailing, 24)
    }

    private func setDelay(_ v: Double) {
        let d = (max(-30, min(30, v)) * 10).rounded() / 10
        engine.subDelay = d
        subDelay = d
    }

    private func pageTitle(_ t: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { trackPage = 0 }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                Text(t)
                Spacer()
            }
            .font(.system(size: 14, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
    }

    private func menuRow(_ title: String, _ value: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { action() }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(value + (value.isEmpty ? "" : " ›"))
                    .foregroundColor(on ? .white : Color(hex: 0xCFD6FF).opacity(0.8))
                    .lineLimit(1)
            }
            .font(.system(size: 14))
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(on ? T.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
    }

    private func trackList(_ list: [TrackOption], _ cur: Int, empty: String,
                           pick: @escaping (Int) -> Void) -> some View {
        Group {
            if list.isEmpty {
                Text(empty).font(.system(size: 13)).foregroundColor(T.dim).padding(12)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(list) { t in
                            Button { pick(t.id) } label: {
                                HStack {
                                    Text(t.name).lineLimit(1)
                                    Spacer()
                                    if t.id == cur { Image(systemName: "checkmark") }
                                }
                                .font(.system(size: 14, weight: t.id == cur ? .bold : .regular))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(t.id == cur ? T.accent : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                                .contentShape(Rectangle())
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }
}

struct LevelBar: View {
    let value: Double
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.white).frame(height: max(4, 150 * value))
            }
            .frame(width: 8, height: 150)
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(.white)
        }
    }
}
