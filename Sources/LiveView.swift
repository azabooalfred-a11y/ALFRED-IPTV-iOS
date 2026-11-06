import SwiftUI

struct PlayRequest: Identifiable {
    let id = UUID()
    let list: [Channel]
    let index: Int
}

struct ChannelRow: View {
    @EnvironmentObject var store: Store
    let ch: Channel
    var showEpg = false
    var on = false
    @State private var now = ""

    var body: some View {
        HStack(spacing: 10) {
            Text("\(ch.num)")
                .font(.system(size: 12))
                .foregroundColor(on ? .white : Color(hex: 0xCFD6FF))
                .frame(width: 32, alignment: .leading)
            LogoImage(url: ch.icon).frame(width: 44, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(ch.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                if showEpg && !now.isEmpty {
                    Text("Now: " + now)
                        .font(.system(size: 12))
                        .foregroundColor(on ? Color.white.opacity(0.8) : T.dim)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button { store.toggleFav(ch) } label: {
                Image(systemName: store.isFav(ch) ? "heart.fill" : "heart")
                    .foregroundColor(store.isFav(ch) ? Color(hex: 0xFF4785) : .white)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.white)
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(on ? T.accent : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .task(id: ch.id) {
            guard showEpg, let api = store.api else { return }
            let list = await EpgCache.shared.programs(api, ch)
            now = list.first?.title ?? ""
        }
    }
}

/// Live TV — sample A: category chips + channel list upright, 3 columns sideways.
struct LiveView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var cats: [Category] = []
    @State private var chans: [Channel] = []
    @State private var counts: [String: Int] = [:]
    @State private var loading = true
    @State private var errText: String?
    @State private var cat = "all"
    @State private var qCh = ""
    @State private var qCat = ""
    @State private var selected: Channel?
    @State private var selNow = ""
    @State private var playing: PlayRequest?
    @State private var isLand = false
    @StateObject private var preview = PlayerEngine()

    private var allCats: [Category] {
        [Category(id: "all", name: "All Channels"), Category(id: "fav", name: "Favorites")] + cats
    }

    private func filtered() -> [Channel] {
        var l: [Channel]
        switch cat {
        case "all": l = chans
        case "fav": l = chans.filter { store.isFav($0) }
        default: l = chans.filter { $0.categoryId == cat }
        }
        let q = qCh.trimmed
        if !q.isEmpty { l = l.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        return l
    }

    var body: some View {
        GeometryReader { g in
            let land = g.size.width > g.size.height
            let list = filtered()
            ZStack {
                AppBackground()
                VStack(spacing: 8) {
                    header
                    if loading {
                        Spacer()
                        ProgressView("Loading channels…").tint(.white).foregroundColor(.white)
                        Spacer()
                    } else if let errText {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "wifi.exclamationmark").font(.system(size: 34))
                            Text(errText).multilineTextAlignment(.center)
                            Pill(icon: "arrow.clockwise", title: "Try again") { Task { await load() } }
                        }
                        .foregroundColor(.white)
                        Spacer()
                    } else if land {
                        landscape(list, g.size)
                    } else {
                        portrait(list)
                    }
                }
                .padding(.horizontal, land ? 20 : 12)
            }
            .onAppear { isLand = land }
            .onChange(of: land) { v in
                isLand = v
                if !v { preview.stop() } else if let s = selected { preview.play(store.api?.liveURL(s)) }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: store.reloadToken) { await load() }
        .onDisappear { preview.stop() }
        .fullScreenCover(item: $playing, onDismiss: {
            if isLand, let s = selected { preview.play(store.api?.liveURL(s)) }
        }) { r in
            PlayerView(list: r.list, index: r.index).environmentObject(store)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            CircleButton(icon: "chevron.left", size: 36) { dismiss() }
            Image("Logo").resizable().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7))
            Text("Live").font(.system(size: 18, weight: .black)).foregroundColor(.white)
            Spacer()
            Clock(size: 16)
        }
        .padding(.top, 4)
    }

    // MARK: upright

    private func portrait(_ list: [Channel]) -> some View {
        VStack(spacing: 8) {
            SearchField(text: $qCh, placeholder: "Search Channels")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(allCats) { c in
                        Button { cat = c.id } label: {
                            Text(c.name)
                                .font(.system(size: 13, weight: cat == c.id ? .bold : .regular))
                                .foregroundColor(.white)
                                .padding(.horizontal, 13).padding(.vertical, 7)
                                .background(cat == c.id ? T.accent : T.field)
                                .overlay(Capsule().stroke(Color.white.opacity(cat == c.id ? 0 : 0.12)))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            channelList(list, showEpg: true, empty: "No channels here") { i in
                preview.stop()
                playing = PlayRequest(list: list, index: i)
            }
        }
        .onAppear { preview.stop() }
    }

    // MARK: sideways

    private func landscape(_ list: [Channel], _ size: CGSize) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 6) {
                SearchField(text: $qCat, placeholder: "Search Category")
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        let q = qCat.trimmed
                        ForEach(allCats.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }) { c in
                            HStack {
                                Text(c.name).font(.system(size: 13)).lineLimit(1)
                                Spacer()
                                Text("\(c.id == "fav" ? store.favCount(in: chans) : counts[c.id] ?? 0)")
                                    .font(.system(size: 11)).foregroundColor(T.dim)
                            }
                            .foregroundColor(.white)
                            .padding(.vertical, 9).padding(.horizontal, 10)
                            .background(cat == c.id ? T.accent.opacity(0.35) : Color.clear)
                            .overlay(alignment: .leading) {
                                if cat == c.id { Rectangle().fill(T.accent).frame(width: 3) }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                            .onTapGesture { cat = c.id }
                        }
                    }
                }
            }
            .frame(width: size.width * 0.23)

            VStack(spacing: 6) {
                SearchField(text: $qCh, placeholder: "Search Channels")
                channelList(list, showEpg: false, empty: "No channels here") { i in
                    let ch = list[i]
                    if selected?.id == ch.id {
                        preview.stop()
                        playing = PlayRequest(list: list, index: i)
                    } else {
                        select(ch)
                    }
                }
            }

            previewColumn(list)
                .frame(width: size.width * 0.27)
        }
    }

    private func previewColumn(_ list: [Channel]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                if selected != nil {
                    VLCVideoView(engine: preview)
                    if preview.buffering { ProgressView().tint(.white) }
                    if preview.failed {
                        Text("This channel isn't working right now.")
                            .font(.system(size: 12)).foregroundColor(T.dim).multilineTextAlignment(.center).padding()
                    }
                } else {
                    Text("Pick a channel to watch it here")
                        .font(.system(size: 12)).foregroundColor(T.dim).multilineTextAlignment(.center).padding()
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture { openFull(list) }

            if let s = selected {
                Text(s.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                if !selNow.isEmpty {
                    Text("Now: " + selNow).font(.system(size: 11)).foregroundColor(T.dim).lineLimit(2)
                }
                HStack(spacing: 6) {
                    smallPill(store.isFav(s) ? "heart.fill" : "heart", "Favorite") { store.toggleFav(s) }
                    smallPill("arrow.up.left.and.arrow.down.right", "Full Screen") { openFull(list) }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(.white)
    }

    private func smallPill(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(T.glass)
            .overlay(Capsule().stroke(Color.white.opacity(0.15)))
            .clipShape(Capsule())
        }
        .buttonStyle(Press())
    }

    private func channelList(_ list: [Channel], showEpg: Bool, empty: String,
                             tap: @escaping (Int) -> Void) -> some View {
        Group {
            if list.isEmpty {
                VStack {
                    Spacer()
                    Text(empty).foregroundColor(T.dim)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(list.indices, id: \.self) { i in
                            ChannelRow(ch: list[i], showEpg: showEpg, on: selected?.id == list[i].id && !showEpg)
                                .onTapGesture { tap(i) }
                        }
                    }
                    .padding(.bottom, 20)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
    }

    private func select(_ ch: Channel) {
        selected = ch
        selNow = ""
        preview.play(store.api?.liveURL(ch))
        Task {
            guard let api = store.api else { return }
            let p = await EpgCache.shared.programs(api, ch)
            if selected?.id == ch.id { selNow = p.first?.title ?? "" }
        }
    }

    private func openFull(_ list: [Channel]) {
        guard let s = selected else { return }
        preview.stop()
        if let i = list.firstIndex(where: { $0.id == s.id }) {
            playing = PlayRequest(list: list, index: i)
        } else {
            playing = PlayRequest(list: [s], index: 0)
        }
    }

    private func load() async {
        guard let api = store.api else { return }
        loading = true
        errText = nil
        do {
            async let c = api.liveCategories()
            async let s = api.liveStreams()
            let (cs, ss) = try await (c, s)
            var n: [String: Int] = ["all": ss.count]
            for ch in ss { n[ch.categoryId, default: 0] += 1 }
            cats = cs.filter { (n[$0.id] ?? 0) > 0 }
            chans = ss
            counts = n
        } catch {
            errText = error.localizedDescription
        }
        loading = false
    }
}
