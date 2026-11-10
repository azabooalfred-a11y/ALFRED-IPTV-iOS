import SwiftUI

struct Tile: View {
    let title: String
    let icon: String
    let colors: [Color]
    var big = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: big ? 24 : 18, weight: .semibold))
                    .frame(width: big ? 50 : 40, height: big ? 50 : 40)
                    .background(Color.white.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: big ? 34 : 20, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundColor(.white)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(Press())
    }
}

/// Home — Option 1: tiles stacked when upright, the TV layout when sideways.
struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var openLive = false
    @State private var openMovies = false
    @State private var openSeries = false
    @State private var openSettings = false
    @State private var openSearch = false
    @State private var update: UpdateInfo?
    @State private var showPlaylists = false
    @State private var showAccount = false
    @State private var toast: String?

    var body: some View {
        GeometryReader { g in
            let land = isLandscape(g)
            ZStack {
                Wallpaper(style: .glow)
                if land {
                    landscape
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                } else {
                    ScrollView(showsIndicators: false) { portrait.padding(.horizontal, 16).padding(.top, 6) }
                }
                if let toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.bottom, 30)
                    }
                    .transition(.opacity)
                }
                if let u = update { UpdateBox(info: u) { update = nil } }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $openLive) { LiveView() }
        .navigationDestination(isPresented: $openMovies) { MediaView(kind: .movie) }
        .navigationDestination(isPresented: $openSeries) { MediaView(kind: .series) }
        .navigationDestination(isPresented: $openSettings) { SettingsView() }
        .navigationDestination(isPresented: $openSearch) { SearchView() }
        .sheet(isPresented: $showPlaylists) { PlaylistsView().environmentObject(store) }
        .alert("Account", isPresented: $showAccount) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(accountText)
        }
        .task(id: store.reloadToken) {
            if store.account == nil { await store.refreshAccount() }
        }
        .task {
            guard !Updater.checkedThisLaunch else { return }
            Updater.checkedThisLaunch = true
            update = await Updater.check()
        }
    }

    private var header: some View {
        HStack {
            Brand(size: 40)
            Spacer()
            CircleButton(icon: "magnifyingglass", size: 40) { openSearch = true }
            Clock(size: 20)
        }
    }

    private var live: some View { Tile(title: "Live TV", icon: "tv", colors: T.live, big: true) { openLive = true } }
    private var movies: some View { Tile(title: "Movies", icon: "play.circle", colors: T.movies) { openMovies = true } }
    private var series: some View { Tile(title: "Series", icon: "film", colors: T.series) { openSeries = true } }
    private var settings: some View { Tile(title: "Settings", icon: "gearshape.fill", colors: T.settings) { openSettings = true } }
    private var reload: some View { Tile(title: "Reload", icon: "arrow.clockwise", colors: T.reload) { doReload() } }

    private var pills: some View {
        HStack(spacing: 8) {
            Pill(icon: "person", title: "Account") { showAccount = true }
            Pill(icon: "list.bullet", title: "Playlists") { showPlaylists = true }
            Pill(icon: "rectangle.portrait.and.arrow.right", title: "Exit") { exit(0) }
        }
    }

    private var expiry: some View {
        HStack(spacing: 6) {
            Circle().fill(store.account == nil ? T.dim : Color.green).frame(width: 7, height: 7)
            Text("\(store.current?.name ?? "") · \(expiryText)")
        }
        .font(.system(size: 13))
        .foregroundColor(Color(hex: 0xCFD6FF))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(T.glass)
        .overlay(Capsule().stroke(Color.white.opacity(0.12)))
        .clipShape(Capsule())
    }

    private var expiryText: String {
        guard let a = store.account else { return "Checking…" }
        guard let e = a.expires else { return "No expiry" }
        return "Expires: " + e.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private var accountText: String {
        guard let a = store.account else { return "Couldn't load the account details. Check your internet." }
        var lines = ["Playlist: \(store.current?.name ?? "")"]
        if !a.username.isEmpty { lines.append("Username: \(a.username)") }
        lines.append("Status: \(a.status)")
        lines.append(expiryText)
        if !a.maxConnections.isEmpty { lines.append("Connections: \(a.maxConnections)") }
        return lines.joined(separator: "\n")
    }

    private var portrait: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.padding(.bottom, 4)
            live.frame(height: 220)
            HStack(spacing: 10) { movies; series }.frame(height: 150)
            HStack(spacing: 10) { settings; reload }.frame(height: 120)
            ScrollView(.horizontal, showsIndicators: false) { pills }
            expiry
        }
        .padding(.bottom, 20)
    }

    private var landscape: some View {
        VStack(spacing: 10) {
            header
            GeometryReader { t in
                HStack(spacing: 8) {
                    live.frame(width: (t.size.width - 16) * 1.6 / 3.6)
                    VStack(spacing: 8) {
                        HStack(spacing: 8) { movies; series }
                        HStack(spacing: 8) { settings; reload }
                    }
                }
            }
            HStack {
                pills
                Spacer()
                expiry
            }
        }
    }

    private func doReload() {
        store.reload()
        withAnimation { toast = "Reloading playlist…" }
        Task {
            await store.refreshAccount()
            withAnimation { toast = store.account == nil ? "Couldn't reach the server" : "Playlist reloaded" }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { toast = nil }
        }
    }
}
