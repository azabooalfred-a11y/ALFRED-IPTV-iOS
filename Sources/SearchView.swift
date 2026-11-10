import SwiftUI

/// Search Everything — sample A: one box, results in Live TV / Movies / Series
/// (three columns sideways, three sections upright).
struct SearchView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var q = ""
    @State private var chans: [Channel] = []
    @State private var movies: [VodItem] = []
    @State private var series: [VodItem] = []
    @State private var loading = true
    @State private var playing: PlayRequest?
    @State private var detail: VodItem?
    @FocusState private var focused: Bool

    private var query: String { q.trimmed }

    private var liveHits: [Channel] {
        guard !query.isEmpty else { return [] }
        return chans.filter { $0.name.localizedCaseInsensitiveContains(query) || "\($0.num)" == query }
    }

    private func hits(_ l: [VodItem]) -> [VodItem] {
        guard !query.isEmpty else { return [] }
        return l.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        GeometryReader { g in
            let land = isLandscape(g)
            ZStack {
                AppBackground()
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        CircleButton(icon: "chevron.left", size: 36) { dismiss() }
                        Text("Search").font(.system(size: 18, weight: .black)).foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.top, 4)
                    SearchField(text: $q, placeholder: "Search channels, movies, series")
                        .focused($focused)
                    if loading {
                        Spacer()
                        ProgressView("Loading…").tint(.white).foregroundColor(.white)
                        Spacer()
                    } else if query.isEmpty {
                        Spacer()
                        Text("Type a name to search Live TV, Movies and Series").foregroundColor(T.dim)
                        Spacer()
                    } else if land {
                        HStack(alignment: .top, spacing: 12) {
                            column("LIVE TV", liveHits.count, T.cyan) { liveList }
                            column("MOVIES", hits(movies).count, Color(hex: 0xB44BFF)) { vodList(hits(movies)) }
                            column("SERIES", hits(series).count, Color(hex: 0x21D3A6)) { vodList(hits(series)) }
                        }
                    } else {
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 14) {
                                section("LIVE TV", liveHits.count, T.cyan) { liveList }
                                section("MOVIES", hits(movies).count, Color(hex: 0xB44BFF)) { vodList(hits(movies)) }
                                section("SERIES", hits(series).count, Color(hex: 0x21D3A6)) { vodList(hits(series)) }
                            }
                            .padding(.bottom, 20)
                        }
                        .scrollDismissesKeyboard(.immediately)
                    }
                }
                .padding(.horizontal, land ? 20 : 12)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: store.reloadToken) { await load() }
        .onAppear { focused = true }
        .fullScreenCover(item: $playing) { r in PlayerView(request: r).environmentObject(store) }
        .fullScreenCover(item: $detail) { DetailView(item: $0).environmentObject(store) }
    }

    // MARK: layout

    private func header(_ t: String, _ n: Int, _ c: Color) -> some View {
        Text("\(t) · \(n)")
            .font(.system(size: 12, weight: .heavy))
            .kerning(1)
            .foregroundColor(c)
    }

    private func column<C: View>(_ t: String, _ n: Int, _ c: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(t, n, c)
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 4) { content() }.padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .frame(maxWidth: .infinity)
    }

    private func section<C: View>(_ t: String, _ n: Int, _ c: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(t, n, c)
            if n == 0 {
                Text("Nothing found").font(.system(size: 13)).foregroundColor(T.dim)
            } else {
                LazyVStack(spacing: 4) { content() }
            }
        }
    }

    private var liveList: some View {
        let l = Array(liveHits.prefix(200))
        return ForEach(l.indices, id: \.self) { i in
            row(icon: l[i].icon, seed: l[i].name, title: l[i].name, sub: "Ch \(l[i].num)", wide: true)
                .onTapGesture { play(l, i) }
        }
    }

    private func vodList(_ l: [VodItem]) -> some View {
        let items = Array(l.prefix(200))
        return ForEach(items) { it in
            row(icon: it.cover, seed: it.name, title: it.name,
                sub: it.rating.isEmpty ? (it.kind == .movie ? "Movie" : "Series") : "★ " + it.rating, wide: false)
                .onTapGesture { detail = it }
        }
    }

    private func row(icon: String, seed: String, title: String, sub: String, wide: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if wide {
                    LogoImage(url: icon)
                } else {
                    Poster(url: icon, seed: seed)
                }
            }
            .frame(width: wide ? 50 : 34, height: wide ? 34 : 50)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                Text(sub).font(.system(size: 11)).foregroundColor(T.dim)
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(.white)
        .padding(7)
        .background(T.glass)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    // MARK: data

    private func load() async {
        guard let api = store.api else { return }
        loading = true
        async let c = try? api.liveStreams()
        async let m = try? api.items(.movie)
        async let s = try? api.items(.series)
        let (cs, ms, ss) = await (c, m, s)
        chans = visible(cs ?? [], "live") { $0.categoryId }
        movies = visible(ms ?? [], "movie") { $0.categoryId }
        series = visible(ss ?? [], "series") { $0.categoryId }
        loading = false
    }

    /// Leaves out hidden categories, and locked ones while Parental Control is on.
    private func visible<Item>(_ l: [Item], _ kind: String, _ cat: (Item) -> String) -> [Item] {
        let hid = store.hiddenSet(kind)
        let lock = store.parentalOn && !store.unlocked ? store.lockedSet(kind) : []
        if hid.isEmpty && lock.isEmpty { return l }
        return l.filter { !hid.contains(cat($0)) && !lock.contains(cat($0)) }
    }

    private func play(_ l: [Channel], _ i: Int) {
        let api = store.api
        let items = l.map { c in
            PlayItem(id: c.id, num: c.num, title: c.name, icon: c.icon, url: api?.liveURL(c), channel: c)
        }
        playing = PlayRequest(items: items, index: i, live: true)
    }
}
