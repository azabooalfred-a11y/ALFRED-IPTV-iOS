import SwiftUI
import UIKit

/// Something the player can play: a live channel, a movie or an episode.
struct PlayItem: Identifiable {
    let id: String
    let num: Int
    let title: String
    let icon: String
    let url: URL?
    var channel: Channel? = nil
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
                VLCVideoView(engine: engine).ignoresSafeArea()

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
        }
        .onDisappear {
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
                HStack {
                    CircleButton(icon: "chevron.left") { dismiss() }
                    Spacer()
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
            .padding(.horizontal, 64)
            .padding(.bottom, 14)
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

    private func start() {
        engine.setVolume(Int(vol * 100))
        engine.play(item.url)
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
        index = (index + step + list.count) % list.count
        start()
        bumpHide()
    }

    private func toggleControls() {
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
            if !Task.isCancelled && !showList && scrub == nil {
                withAnimation { controls = false }
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
