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

/// Movies / Series — category bar A: categories always on the left, posters of the picked one on the right.
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
    @State private var cat = "all"
    @State private var query = ""
    @State private var askPin = false
    @State private var pendingCat: String?

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
                    } else {
                        HStack(alignment: .top, spacing: land ? 12 : 8) {
                            categoryBar(land: land)
                                .frame(width: land ? min(210, g.size.width * 0.23) : 120)
                            VStack(spacing: 8) {
                                SearchField(text: $query, placeholder: "Search \(catName(cat))")
                                MediaGridBody(items: shown, minWidth: land ? 84 : 100)
                            }
                        }
                    }
                }
                .padding(.horizontal, land ? 20 : 10)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: VodItem.self) { DetailView(item: $0) }
        .task(id: store.reloadToken) { await load() }
        .onChange(of: sortMode) { _ in regroup() }
        .pinPrompt($askPin) { if let c = pendingCat { cat = c } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            CircleButton(icon: "chevron.left", size: 36) { dismiss() }
            Image("Logo").resizable().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7))
            Text(kind.title).font(.system(size: 18, weight: .black)).foregroundColor(.white)
            Spacer()
            Clock(size: 16)
        }
        .padding(.top, 4)
    }

    // MARK: category bar

    private var allCats: [Category] {
        let hid = store.hiddenSet(hk)
        return [Category(id: "all", name: "All"), Category(id: "fav", name: "Favorites"),
                Category(id: "history", name: "Recently Watched"), Category(id: "recent", name: "Recently Added")]
            + cats.filter { !hid.contains($0.id) && !(byCat[$0.id]?.isEmpty ?? true) }
    }

    private func categoryBar(land: Bool) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(allCats) { c in
                    let locked = store.isLocked(hk, c.id)
                    HStack(spacing: 4) {
                        Text((locked ? "🔒 " : "") + c.name)
                            .font(.system(size: land ? 13 : 12, weight: cat == c.id ? .bold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text("\(count(c.id))").font(.system(size: 10)).foregroundColor(cat == c.id ? .white.opacity(0.8) : T.dim)
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 9).padding(.horizontal, 8)
                    .background(cat == c.id ? T.accent : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                    .onTapGesture { pick(c.id) }
                }
            }
            .padding(6)
        }
        .background(T.glass)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.bottom, 8)
    }

    private func pick(_ id: String) {
        if store.isLocked(hk, id) {
            pendingCat = id
            askPin = true
        } else {
            cat = id
            query = ""
        }
    }

    private func catName(_ id: String) -> String { allCats.first { $0.id == id }?.name ?? kind.title }

    private func count(_ id: String) -> Int {
        switch id {
        case "all": return items.filter(visible).count
        case "fav", "history", "recent": return itemsFor(id).count
        default: return byCat[id]?.count ?? 0
        }
    }

    // MARK: data

    private func visible(_ it: VodItem) -> Bool {
        !store.hiddenSet(hk).contains(it.categoryId) && !store.isLocked(hk, it.categoryId)
    }

    private func itemsFor(_ id: String) -> [VodItem] {
        switch id {
        case "all": return Sorts.vod(items.filter(visible), sortMode)
        case "recent": return Array(Sorts.vod(items.filter(visible), 3).prefix(100))
        case "fav": return items.filter { store.isFav($0.favKey) && visible($0) }
        case "history":
            let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return store.historyIds(hk).compactMap { byId[$0] }.filter(visible)
        default: return store.isLocked(hk, id) ? [] : (byCat[id] ?? [])
        }
    }

    private var shown: [VodItem] {
        let l = itemsFor(cat)
        let q = query.trimmed
        return q.isEmpty ? l : l.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

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
    var minWidth: CGFloat = 100

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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth, maximum: minWidth * 1.3), spacing: 8)], spacing: 8) {
                    ForEach(items) { it in
                        NavigationLink(value: it) {
                            PosterCard(item: it, w: minWidth, h: minWidth * 1.48).frame(maxWidth: .infinity)
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
