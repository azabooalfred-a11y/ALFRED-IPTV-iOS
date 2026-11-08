import SwiftUI

/// Details page — sample B: poster beside the info, season drop-down, numbered episodes.
struct DetailView: View {
    let item: VodItem
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var d = VodDetails()
    @State private var loading = true
    @State private var season = 0
    @State private var playing: PlayRequest?

    private var episodes: [Episode] { (d.episodes[season] ?? []).sorted { $0.num < $1.num } }

    var body: some View {
        GeometryReader { g in
            let land = isLandscape(g)
            ZStack {
                AppBackground()
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        CircleButton(icon: "chevron.left", size: 36) { dismiss() }
                        Image("Logo").resizable().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7))
                        Text(item.kind.title).font(.system(size: 18, weight: .black))
                        Spacer()
                        Clock(size: 16)
                    }
                    .padding(.top, 4)
                    if land {
                        HStack(alignment: .top, spacing: 16) {
                            PosterCard(item: item, w: 130, h: 190)
                            ScrollView(showsIndicators: false) { info(compact: true) }.frame(width: 240)
                            if item.kind == .series { episodeList } else { Spacer() }
                        }
                    } else {
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top, spacing: 12) {
                                    PosterCard(item: item, w: 112, h: 165)
                                    info(compact: false)
                                }
                                if !d.plot.isEmpty {
                                    Text(d.plot).font(.system(size: 13)).foregroundColor(Color(hex: 0xCFD6FF))
                                }
                                if !d.cast.isEmpty {
                                    Text("Cast: " + d.cast).font(.system(size: 12)).foregroundColor(T.dim)
                                }
                                if item.kind == .series { episodeRows }
                            }
                            .padding(.bottom, 20)
                        }
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, land ? 20 : 16)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard let api = store.api else { return }
            d = await api.details(item)
            season = lastEp?.season ?? d.seasons.first ?? 0
            loading = false
        }
        .fullScreenCover(item: $playing) { r in PlayerView(request: r).environmentObject(store) }
    }

    private var metaLine: String {
        var parts: [String] = []
        if !d.year.isEmpty { parts.append(d.year) }
        if !d.genre.isEmpty { parts.append(d.genre) }
        return parts.joined(separator: " · ")
    }

    private var metaLine2: String {
        var parts: [String] = []
        if !item.rating.isEmpty { parts.append("★ " + item.rating) }
        if item.kind == .series && !d.seasons.isEmpty { parts.append("\(d.seasons.count) Season\(d.seasons.count == 1 ? "" : "s")") }
        if item.kind == .movie && !d.duration.isEmpty { parts.append(d.duration) }
        return parts.joined(separator: " · ")
    }

    private func info(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name).font(.system(size: 20, weight: .black)).lineLimit(3)
            if !metaLine.isEmpty { Text(metaLine).font(.system(size: 12)).foregroundColor(T.dim) }
            if !metaLine2.isEmpty { Text(metaLine2).font(.system(size: 12)).foregroundColor(T.dim) }
            if compact && !d.plot.isEmpty {
                Text(d.plot).font(.system(size: 12)).foregroundColor(Color(hex: 0xCFD6FF)).lineLimit(6)
            }
            Button(action: playMain) {
                HStack {
                    if loading && item.kind == .series { ProgressView().tint(.white) } else {
                        Image(systemName: "play.fill")
                        Text(playTitle)
                    }
                }
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(LinearGradient(colors: T.live, startPoint: .leading, endPoint: .trailing))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(Press())
            .disabled(item.kind == .series && item.directURL.isEmpty && episodes.isEmpty)
            Button { store.toggleFav(item.favKey) } label: {
                Label("Favorite", systemImage: store.isFav(item.favKey) ? "heart.fill" : "heart")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(T.glass)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15)))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    /// The episode watched last (for "Continue S1 E3").
    private var lastEp: Episode? {
        guard let id = store.lastEpisode(item.id) else { return nil }
        return d.episodes.values.flatMap { $0 }.first { $0.id == id }
    }

    private var playTitle: String {
        if item.kind == .movie || !item.directURL.isEmpty {
            let t = store.positionText(item.favKey)
            return store.progress(item.favKey) > 0.01 ? "Continue (\(t))" : "Play"
        }
        if let e = lastEp { return "Continue S\(e.season) E\(e.num)" }
        guard let e = episodes.first else { return "Play" }
        return "Play S\(e.season) E\(e.num)"
    }

    private var seasonMenu: some View {
        Menu {
            ForEach(d.seasons, id: \.self) { s in
                Button("Season \(s)") { season = s }
            }
        } label: {
            HStack {
                Text(d.seasons.isEmpty ? (loading ? "Loading…" : "No episodes") : "Season \(season)")
                Spacer()
                Image(systemName: "chevron.down")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(T.field)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var episodeRows: some View {
        VStack(spacing: 0) {
            seasonMenu.padding(.bottom, 6)
            ForEach(Array(episodes.enumerated()), id: \.element.id) { i, e in
                episodeRow(i, e)
            }
        }
    }

    private var episodeList: some View {
        VStack(spacing: 6) {
            seasonMenu
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { i, e in
                        episodeRow(i, e)
                    }
                }
            }
        }
    }

    private func episodeRow(_ i: Int, _ e: Episode) -> some View {
        Button { playEpisode(i) } label: {
            HStack(spacing: 12) {
                Text("\(e.num)").font(.system(size: 14, weight: .semibold)).foregroundColor(T.cyan).frame(width: 26, alignment: .leading)
                Text(e.title.isEmpty ? "Episode \(e.num)" : e.title).font(.system(size: 14)).lineLimit(1)
                Spacer()
                if store.progress("ep:" + e.id) > 0.01 {
                    Text(store.positionText("ep:" + e.id)).font(.system(size: 11)).foregroundColor(T.cyan)
                } else if !e.duration.isEmpty { Text(e.duration).font(.system(size: 11)).foregroundColor(T.dim) }
                Image(systemName: "play.fill").font(.system(size: 11))
            }
            .foregroundColor(.white)
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
            .contentShape(Rectangle())
        }
    }

    private func playMain() {
        guard let api = store.api else { return }
        if item.kind == .movie || !item.directURL.isEmpty {
            store.addHistory(item.kind.rawValue, item.id)
            playing = PlayRequest(items: [PlayItem(id: item.id, num: 1, title: item.name, icon: item.cover,
                                                   url: api.movieURL(item, ext: d.ext), resumeKey: item.favKey)],
                                  index: 0, live: false)
        } else if let last = lastEp {
            season = last.season
            if let i = episodes.firstIndex(where: { $0.id == last.id }) { playEpisode(i) }
        } else if !episodes.isEmpty {
            playEpisode(0)
        }
    }

    private func playEpisode(_ i: Int) {
        guard let api = store.api else { return }
        store.addHistory("series", item.id)
        let items = episodes.map { e in
            PlayItem(id: e.id, num: e.num,
                     title: "\(item.name) · S\(e.season) E\(e.num)",
                     icon: e.image.isEmpty ? item.cover : e.image, url: api.episodeURL(e),
                     resumeKey: "ep:" + e.id, seriesId: item.id)
        }
        playing = PlayRequest(items: items, index: i, live: false)
    }
}
