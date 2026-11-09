import SwiftUI

struct CatRoute: Hashable {
    let id: String
    let title: String
}

struct PosterCard: View {
    let item: VodItem
    var w: CGFloat = 105
    var h: CGFloat = 155
    var fav = false
    var progress: Double = 0

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
        .overlay(alignment: .bottom) {
            let f = progress
            if f > 0.01 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.25))
                        Rectangle().fill(T.cyan).frame(width: g.size.width * f)
                    }
                }
                .frame(height: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if fav {
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
            RemoteImage(url: url, maxPixels: 360) { Color.clear }
        }
        .clipped()
    }
}

/// Movies / Series — category bar A: categories always on the left, posters of the picked one on the right.
/// Lists are worked out once (when loaded / when something changes), not on every redraw, so it stays fast.
struct MediaView: View {
    let kind: Kind
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("vodSort") private var sortMode = 0

    @State private var cats: [Category] = []
    @State private var items: [VodItem] = []
    @State private var loading = true
    @State private var errText: String?
    @State private var cat = "all"
    @State private var query = ""
    @State private var askPin = false
    @State private var pendingCat: String?
    @State private var detail: VodItem?

    // worked out in rebuild()
    @State private var barCats: [Category] = []
    @State private var lists: [String: [VodItem]] = [:]
    @State private var shown: [VodItem] = []
    @State private var searchTask: Task<Void, Never>?

    private var hk: String { kind.rawValue }
    private let special: Set<String> = ["continue", "all", "fav", "history", "recent"]

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
                                MediaGridBody(items: shown, minWidth: land ? 84 : 100, fav: { store.isFav($0.favKey) },
                                              progress: { $0.kind == .movie ? store.progress($0.favKey) : 0 }) { detail = $0 }
                                    .id(cat)
                            }
                        }
                    }
                }
                .padding(.horizontal, land ? 20 : 10)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $detail, onDismiss: { rebuild() }) { DetailView(item: $0).environmentObject(store) }
        .task(id: store.reloadToken) { await load() }
        .onChange(of: sortMode) { _ in rebuild() }
        .onChange(of: cat) { _ in updateShown() }
        .onChange(of: query) { _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !Task.isCancelled { updateShown() }
            }
        }
        .pinPrompt($askPin) {
            rebuild()
            if let c = pendingCat { cat = c }
        }
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

    private func categoryBar(land: Bool) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(barCats) { c in
                    let locked = store.isLocked(hk, c.id)
                    HStack(spacing: 4) {
                        Text((locked ? "🔒 " : "") + c.name)
                            .font(.system(size: land ? 13 : 12, weight: cat == c.id ? .bold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text("\(lists[c.id]?.count ?? 0)").font(.system(size: 10))
                            .foregroundColor(cat == c.id ? .white.opacity(0.8) : T.dim)
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 9).padding(.horizontal, 8)
                    .background(cat == c.id ? T.accent : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                    .onTapGesture { pick(c.id) }
                    .modifier(CategoryMoveMenu(enabled: !special.contains(c.id)) { how in
                        let real = barCats.filter { !special.contains($0.id) }
                        store.moveCategory(hk, c.id, how, current: real)
                        withAnimation { rebuild() }
                    })
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
            query = ""
            cat = id
        }
    }

    private func catName(_ id: String) -> String { barCats.first { $0.id == id }?.name ?? kind.title }

    // MARK: data (worked out once)

    private func rebuild() {
        let hid = store.hiddenSet(hk)
        let lock = store.parentalOn && !store.unlocked ? store.lockedSet(hk) : []
        let sorted = Sorts.vod(items, sortMode)
        var byCat: [String: [VodItem]] = [:]
        var visible: [VodItem] = []
        visible.reserveCapacity(sorted.count)
        for it in sorted {
            if hid.contains(it.categoryId) { continue }
            byCat[it.categoryId, default: []].append(it)
            if !lock.contains(it.categoryId) { visible.append(it) }
        }
        var l: [String: [VodItem]] = byCat
        for k in lock { l[k] = [] }
        l["all"] = visible
        l["recent"] = Array(visible.sorted { $0.added > $1.added }.prefix(100))
        l["fav"] = visible.filter { store.isFav($0.favKey) }
        let byId = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        l["history"] = store.historyIds(hk).compactMap { byId[$0] }
        if kind == .movie {
            l["continue"] = visible.filter { store.progress($0.favKey) > 0.01 }
                .sorted { store.savedAt($0.favKey) > store.savedAt($1.favKey) }
        } else {
            l["continue"] = visible.filter { store.lastEpisode($0.id) != nil }
                .sorted { store.lastEpisodeAt($0.id) > store.lastEpisodeAt($1.id) }
        }
        lists = l
        barCats = [Category(id: "continue", name: "Continue Watching"),
                   Category(id: "all", name: "All"), Category(id: "fav", name: "Favorites"),
                   Category(id: "history", name: "Recently Watched"), Category(id: "recent", name: "Recently Added")]
            + store.ordered(hk, cats.filter { !hid.contains($0.id) && !(byCat[$0.id]?.isEmpty ?? true) })
        updateShown()
    }

    private func updateShown() {
        let base = lists[cat] ?? []
        let q = query.trimmed
        shown = q.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(q) }
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
            rebuild()
            if cat == "all" && !(lists["continue"]?.isEmpty ?? true) { cat = "continue" }
        } catch {
            errText = error.localizedDescription
        }
        loading = false
    }
}

struct MediaGridBody: View {
    let items: [VodItem]
    var minWidth: CGFloat = 100
    var fav: (VodItem) -> Bool = { _ in false }
    var progress: (VodItem) -> Double = { _ in 0 }
    let open: (VodItem) -> Void

    var body: some View {
        if items.isEmpty {
            VStack {
                Spacer()
                Text("Nothing here").foregroundColor(T.dim)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth, maximum: minWidth * 1.3), spacing: 8)], spacing: 8) {
                    ForEach(items) { it in
                        Button { open(it) } label: {
                            PosterCard(item: it, w: minWidth, h: minWidth * 1.48, fav: fav(it), progress: progress(it))
                                .frame(maxWidth: .infinity)
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
