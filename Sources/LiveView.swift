import SwiftUI

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
    @State private var askPin = false
    @State private var pendingCat: String?
    @State private var showGuide = false
    @StateObject private var preview = PlayerEngine()
    @AppStorage("liveCatSort") private var catSort = 0
    @AppStorage("liveChSort") private var chSort = 0

    /// Real categories in the order shown (saved press-and-hold order wins over the sort setting).
    private var realCats: [Category] {
        let hid = store.hiddenSet("live")
        return store.ordered("live", Sorts.cats(cats.filter { !hid.contains($0.id) }, catSort))
    }

    private var allCats: [Category] {
        [Category(id: "all", name: "All Channels"), Category(id: "fav", name: "Favorites"),
         Category(id: "recent", name: "Recently Watched")] + realCats
    }

    private func moveMenu(_ c: Category) -> CategoryMoveMenu {
        let special = ["all", "fav", "recent"].contains(c.id)
        return CategoryMoveMenu(enabled: !special) { how in
            withAnimation { store.moveCategory("live", c.id, how, current: realCats) }
        }
    }

    private func pick(_ id: String) {
        if store.isLocked("live", id) {
            pendingCat = id
            askPin = true
        } else {
            cat = id
        }
    }

    private func filtered() -> [Channel] {
        var l = channels(in: cat)
        let q = qCh.trimmed
        if !q.isEmpty { l = l.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        return l
    }

    /// Channels of one category, in the order shown (also used by the TV Guide).
    private func channels(in cat: String) -> [Channel] {
        let hid = store.hiddenSet("live")
        let lock = store.parentalOn && !store.unlocked ? store.lockedSet("live") : []
        let visible = chans.filter { !hid.contains($0.categoryId) && !lock.contains($0.categoryId) }
        var l: [Channel]
        switch cat {
        case "all": l = visible
        case "fav": l = visible.filter { store.isFav($0) }
        case "recent":
            let byId = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            l = store.historyIds("live").compactMap { byId[$0] }
        default: l = chans.filter { $0.categoryId == cat }
        }
        if cat != "recent" { l = Sorts.chans(l, chSort) }
        return l
    }

    var body: some View {
        GeometryReader { g in
            let land = isLandscape(g)
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
            PlayerView(request: r).environmentObject(store)
        }
        .pinPrompt($askPin) { if let c = pendingCat { cat = c } }
        .fullScreenCover(isPresented: $showGuide, onDismiss: {
            if isLand, let s = selected { preview.play(store.api?.liveURL(s)) }
        }) {
            GuideView(categories: allCats.filter { !store.isLocked("live", $0.id) },
                      start: store.isLocked("live", cat) ? "all" : cat,
                      channelsFor: { channels(in: $0) })
                .environmentObject(store)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            CircleButton(icon: "chevron.left", size: 36) { dismiss() }
            Image("Logo").resizable().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7))
            Text("Live").font(.system(size: 18, weight: .black)).foregroundColor(.white)
            Spacer(minLength: 6)
            LiveTitle()
            Spacer(minLength: 6)
            Button {
                preview.stop()
                showGuide = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(isLand ? "TV Guide" : "Guide")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(T.glass)
                .overlay(Capsule().stroke(Color.white.opacity(0.15)))
                .clipShape(Capsule())
            }
            .buttonStyle(Press())
            Clock(size: 16).lineLimit(1).fixedSize()
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
                        Button { pick(c.id) } label: {
                            Text((store.isLocked("live", c.id) ? "🔒 " : "") + c.name)
                                .font(.system(size: 13, weight: cat == c.id ? .bold : .regular))
                                .foregroundColor(.white)
                                .padding(.horizontal, 13).padding(.vertical, 7)
                                .background(cat == c.id ? T.accent : T.field)
                                .overlay(Capsule().stroke(Color.white.opacity(cat == c.id ? 0 : 0.12)))
                                .clipShape(Capsule())
                        }
                        .modifier(moveMenu(c))
                    }
                }
            }
            channelList(list, showEpg: true, empty: "No channels here") { i in
                preview.stop()
                playing = request(list, i)
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
                                Text((store.isLocked("live", c.id) ? "🔒 " : "") + c.name).font(.system(size: 13)).lineLimit(1)
                                Spacer()
                                Text(countText(c.id))
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
                            .onTapGesture { pick(c.id) }
                            .modifier(moveMenu(c))
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
                        playing = request(list, i)
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
            .contentShape(Rectangle())
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
            playing = request(list, i)
        } else {
            playing = request([s], 0)
        }
    }

    private func request(_ list: [Channel], _ i: Int) -> PlayRequest {
        let api = store.api
        let items = list.map { c in
            PlayItem(id: c.id, num: c.num, title: c.name, icon: c.icon, url: api?.liveURL(c), channel: c)
        }
        return PlayRequest(items: items, index: i, live: true)
    }

    private func countText(_ id: String) -> String {
        switch id {
        case "fav": return "\(store.favCount(in: chans))"
        case "recent": return "\(store.historyIds("live").count)"
        default: return "\(counts[id] ?? 0)"
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


/// Title A (same as Android Live): ALFRED in cyan, a thin glowing line, IPTV PLAYER underneath.
struct LiveTitle: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            block(20, 8, 6)
            block(15, 7, 4)
            block(12, 6, 2.5)
        }
    }

    private func block(_ big: CGFloat, _ small: CGFloat, _ spacing: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text("ALFRED")
                .font(.system(size: big, weight: .black))
                .kerning(big * 0.15)
                .foregroundColor(Color(hex: 0x00DCFF))
            Rectangle()
                .fill(LinearGradient(colors: [.clear, T.cyan, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
            Text("IPTV PLAYER")
                .font(.system(size: small, weight: .medium))
                .kerning(spacing)
                .foregroundColor(Color(hex: 0xCFD6FF))
        }
        .lineLimit(1)
        .fixedSize()
    }
}
