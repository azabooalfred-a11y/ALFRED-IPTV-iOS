import SwiftUI

struct CatRoute: Hashable {
    let id: String
    let title: String
}

struct PosterCard: View {
    @EnvironmentObject var store: Store
    let item: VodItem
    var w: CGFloat = 105
    var h: CGFloat = 155

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Poster(url: item.cover, seed: item.name)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            Text(item.name)
                .font(.system(size: 11, weight: .bold))
                .lineLimit(2)
                .padding(6)
        }
        .overlay(alignment: .topLeading) {
            if !item.rating.isEmpty {
                Text("★ " + item.rating)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .padding(5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if store.isFav(item.favKey) {
                Image(systemName: "heart.fill").font(.system(size: 11)).foregroundColor(Color(hex: 0xFF4785)).padding(6)
            }
        }
        .foregroundColor(.white)
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Cover picture, or a colored card with the name while it loads / if there is none.
struct Poster: View {
    let url: String
    let seed: String

    private static let pal: [[Color]] = [
        [Color(hex: 0x7B2FF7), Color(hex: 0xF107A3)], [Color(hex: 0x0F9B8E), Color(hex: 0x1E3C72)],
        [Color(hex: 0xF12711), Color(hex: 0xF5AF19)], [Color(hex: 0x4568DC), Color(hex: 0xB06AB3)],
        [Color(hex: 0x11998E), Color(hex: 0x38EF7D)], [Color(hex: 0xC33764), Color(hex: 0x1D2671)],
    ]

    var body: some View {
        let c = Poster.pal[seed.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Poster.pal.count]
        ZStack {
            LinearGradient(colors: c, startPoint: .topLeading, endPoint: .bottomTrailing)
            AsyncImage(url: URL(string: url)) { phase in
                if let img = phase.image { img.resizable().scaledToFill() } else { Color.clear }
            }
        }
        .clipped()
    }
}

/// Movies / Series — sample B: featured title on top, then rows per category.
struct MediaView: View {
    let kind: Kind
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("vodSort") private var sortMode = 0

    @State private var cats: [Category] = []
    @State private var items: [VodItem] = []
    @State private var byCat: [String: [VodItem]] = [:]
    @State private var loading = true
    @State private var errText: String?
    @State private var searching = false
    @State private var query = ""
    @State private var playing: PlayRequest?
    @State private var askPin = false

    private var hk: String { kind.rawValue }

    var body: some View {
        GeometryReader { g in
            let land = isLandscape(g)
            ZStack {
                AppBackground()
                VStack(spacing: 8) {
                    header
                    if loading {
                        Spacer()
                        ProgressView("Loading \(kind.title.lowercased())…").tint(.white).foregroundColor(.white)
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
                    } else if items.isEmpty {
                        Spacer()
                        Text("No \(kind.title.lowercased()) in this playlist").foregroundColor(T.dim)
                        Spacer()
                    } else if searching && !query.trimmed.isEmpty {
                        MediaGridBody(items: items.filter { $0.name.localizedCaseInsensitiveContains(query.trimmed) && visible($0) })
                    } else if land {
                        HStack(alignment: .top, spacing: 14) {
                            if let f = featured { hero(f).frame(width: g.size.width * 0.34) }
                            ScrollView(showsIndicators: false) { rows(card: CGSize(width: 82, height: 120)) }
                        }
                        .padding(.bottom, 8)
                    } else {
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 4) {
                                if let f = featured { hero(f).frame(height: 190) }
                                rows(card: CGSize(width: 100, height: 148))
                            }
                            .padding(.bottom, 20)
                        }
                    }
                }
                .padding(.horizontal, land ? 20 : 14)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: VodItem.self) { DetailView(item: $0) }
        .navigationDestination(for: CatRoute.self) { r in
            MediaGrid(title: r.title, items: itemsFor(r.id))
        }
        .task(id: store.reloadToken) { await load() }
        .onChange(of: sortMode) { _ in regroup() }
        .fullScreenCover(item: $playing) { r in PlayerView(request: r).environmentObject(store) }
        .pinPrompt($askPin) {}
    }

    private var header: some View {
        HStack(spacing: 10) {
            CircleButton(icon: "chevron.left", size: 36) { dismiss() }
            if searching {
                SearchField(text: $query, placeholder: "Search \(kind.title)")
                Button("Cancel") { withAnimation { searching = false; query = "" } }
                    .font(.system(size: 14)).foregroundColor(T.cyan)
            } else {
                Image("Logo").resizable().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7))
                Text(kind.title).font(.system(size: 18, weight: .black)).foregroundColor(.white)
                Spacer()
                CircleButton(icon: "magnifyingglass", size: 36) { withAnimation { searching = true } }
                Clock(size: 16)
            }
        }
        .padding(.top, 4)
    }

    // MARK: featured + rows

    private func visible(_ it: VodItem) -> Bool {
        !store.hiddenSet(hk).contains(it.categoryId) && !store.isLocked(hk, it.categoryId)
    }

    private var recent: [VodItem] {
        Array(items.filter(visible).sorted { $0.added > $1.added }.prefix(20))
    }

    private var featured: VodItem? { recent.first ?? items.first(where: visible) }

    private func itemsFor(_ id: String) -> [VodItem] {
        switch id {
        case "recent": return Sorts.vod(items.filter(visible), 3)
        case "fav": return items.filter { store.isFav($0.favKey) && visible($0) }
        case "history":
            let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return store.historyIds(hk).compactMap { byId[$0] }.filter(visible)
        default: return byCat[id] ?? []
        }
    }

    private func hero(_ f: VodItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            Poster(url: f.cover, seed: f.name)
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(f.name).font(.system(size: 22, weight: .black)).lineLimit(2).multilineTextAlignment(.leading)
                Text([catName(f.categoryId), f.rating.isEmpty ? "" : "★ " + f.rating].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
                HStack(spacing: 8) {
                    if f.kind == .movie {
                        Button { play(f) } label: { heroPill("Play", "play.fill", solid: true) }
                        NavigationLink(value: f) { heroPill("Info", "info.circle", solid: false) }
                    } else {
                        NavigationLink(value: f) { heroPill("Episodes", "list.bullet", solid: true) }
                    }
                    Button { store.toggleFav(f.favKey) } label: {
                        heroPill("Favorite", store.isFav(f.favKey) ? "heart.fill" : "heart", solid: false)
                    }
                }
                .padding(.top, 4)
            }
            .padding(14)
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func heroPill(_ t: String, _ icon: String, solid: Bool) -> some View {
        Label(t, systemImage: icon)
            .font(.system(size: 13, weight: solid ? .heavy : .semibold))
            .foregroundColor(solid ? Color(hex: 0x0A2156) : .white)
            .padding(.horizontal, solid ? 16 : 12).padding(.vertical, 8)
            .background(solid ? AnyShapeStyle(Color.white) : AnyShapeStyle(T.glass))
            .clipShape(Capsule())
    }

    private func catName(_ id: String) -> String { cats.first { $0.id == id }?.name ?? "" }

    private func rows(card: CGSize) -> some View {
        let hid = store.hiddenSet(hk)
        let shownCats = Sorts.cats(cats.filter { !hid.contains($0.id) && !(byCat[$0.id]?.isEmpty ?? true) }, 0)
        return LazyVStack(alignment: .leading, spacing: 4) {
            let hist = itemsFor("history")
            if !hist.isEmpty { row(CatRoute(id: "history", title: "Recently Watched"), Array(hist.prefix(20)), card) }
            let fav = itemsFor("fav")
            if !fav.isEmpty { row(CatRoute(id: "fav", title: "Favorites"), Array(fav.prefix(20)), card) }
            if !recent.isEmpty { row(CatRoute(id: "recent", title: "Recently Added"), recent, card) }
            ForEach(shownCats) { c in
                if store.isLocked(hk, c.id) {
                    lockedRow(c)
                } else {
                    row(CatRoute(id: c.id, title: c.name), Array((byCat[c.id] ?? []).prefix(20)), card)
                }
            }
        }
    }

    private func row(_ r: CatRoute, _ list: [VodItem], _ card: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(r.title).font(.system(size: 15, weight: .heavy)).lineLimit(1)
                Spacer()
                NavigationLink(value: r) {
                    Text("See all ›").font(.system(size: 12)).foregroundColor(T.cyan)
                }
            }
            .foregroundColor(.white)
            .padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(list) { it in
                        NavigationLink(value: it) { PosterCard(item: it, w: card.width, h: card.height) }
                            .buttonStyle(Press())
                    }
                }
            }
        }
    }

    private func lockedRow(_ c: Category) -> some View {
        Button { askPin = true } label: {
            HStack {
                Image(systemName: "lock.fill")
                Text(c.name).font(.system(size: 15, weight: .heavy))
                Spacer()
                Text("Locked · tap to unlock").font(.system(size: 12)).foregroundColor(T.dim)
            }
            .foregroundColor(.white)
            .padding(12)
            .background(T.glass)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.top, 8)
    }

    private func play(_ f: VodItem) {
        guard f.kind == .movie, let api = store.api else { return }
        store.addHistory(hk, f.id)
        playing = PlayRequest(items: [PlayItem(id: f.id, num: 1, title: f.name, icon: f.cover, url: api.movieURL(f))],
                              index: 0, live: false)
    }

    // MARK: data

    private func regroup() {
        var g: [String: [VodItem]] = [:]
        for it in Sorts.vod(items, sortMode) { g[it.categoryId, default: []].append(it) }
        byCat = g
    }

    private func load() async {
        guard let api = store.api else { return }
        loading = true
        errText = nil
        do {
            async let c = api.categories(kind)
            async let s = api.items(kind)
            let (cs, ss) = try await (c, s)
            cats = cs
            items = ss
            regroup()
        } catch {
            errText = error.localizedDescription
        }
        loading = false
    }
}

/// "See all": every title of one category, with search.
struct MediaGrid: View {
    let title: String
    let items: [VodItem]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        GeometryReader { g in
            let land = isLandscape(g)
            ZStack {
                AppBackground()
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        CircleButton(icon: "chevron.left", size: 36) { dismiss() }
                        Text(title).font(.system(size: 18, weight: .black)).foregroundColor(.white).lineLimit(1)
                        Spacer()
                        Clock(size: 16)
                    }
                    .padding(.top, 4)
                    SearchField(text: $query, placeholder: "Search")
                    MediaGridBody(items: query.trimmed.isEmpty ? items
                                  : items.filter { $0.name.localizedCaseInsensitiveContains(query.trimmed) })
                }
                .padding(.horizontal, land ? 20 : 14)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct MediaGridBody: View {
    let items: [VodItem]

    var body: some View {
        if items.isEmpty {
            VStack {
                Spacer()
                Text("Nothing found").foregroundColor(T.dim)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 130), spacing: 8)], spacing: 8) {
                    ForEach(items) { it in
                        NavigationLink(value: it) {
                            PosterCard(item: it, w: 105, h: 155).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(Press())
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }
}
