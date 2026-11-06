import Foundation
import SwiftUI

struct Playlist: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var base: String
    var user: String
    var pass: String
    var m3u: String

    var isM3u: Bool { !m3u.isEmpty }
}

/// Saved playlists, the one in use, favorites and account info.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var currentIndex = -1
    @Published var account: AccountInfo?
    @Published private(set) var reloadToken = UUID()
    @Published private var favs: [String: Set<String>] = [:]

    private let d = UserDefaults.standard

    init() {
        if let data = d.data(forKey: "playlists"),
           let list = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = list
        }
        currentIndex = d.object(forKey: "current") as? Int ?? -1
        if let raw = d.dictionary(forKey: "favs") as? [String: [String]] {
            favs = raw.mapValues { Set($0) }
        }
    }

    var current: Playlist? {
        playlists.indices.contains(currentIndex) ? playlists[currentIndex] : nil
    }

    var api: Xtream? { current.map { Xtream(playlist: $0) } }

    private func save() {
        d.set(try? JSONEncoder().encode(playlists), forKey: "playlists")
        d.set(currentIndex, forKey: "current")
    }

    /// Adds a playlist (or updates the same server + user) and starts using it.
    func add(_ new: Playlist, account: AccountInfo) {
        var p = new
        if let i = playlists.firstIndex(where: { $0.base == p.base && $0.user == p.user && $0.m3u == p.m3u }) {
            p.id = playlists[i].id
            if p.name.isEmpty { p.name = playlists[i].name }
            playlists[i] = p
            currentIndex = i
        } else {
            if p.name.isEmpty { p.name = "Playlist \(playlists.count + 1)" }
            playlists.append(p)
            currentIndex = playlists.count - 1
        }
        save()
        reload()
        self.account = account
    }

    func select(_ i: Int) {
        currentIndex = i
        save()
        reload()
    }

    func remove(_ i: Int) {
        guard playlists.indices.contains(i) else { return }
        let gone = playlists.remove(at: i)
        favs[gone.id.uuidString] = nil
        if currentIndex == i { currentIndex = -1 } else if currentIndex > i { currentIndex -= 1 }
        save()
        saveFavs()
        reload()
    }

    /// Fresh lists from the server.
    func reload() {
        Xtream.clearCache()
        EpgCache.shared.clear()
        account = nil
        reloadToken = UUID()
    }

    func refreshAccount() async {
        guard let api else { return }
        if let a = try? await api.login() { account = a }
    }

    // MARK: favorites

    func isFav(_ c: Channel) -> Bool {
        guard let p = current else { return false }
        return favs[p.id.uuidString]?.contains(c.id) ?? false
    }

    func favCount(in list: [Channel]) -> Int {
        guard let p = current, let set = favs[p.id.uuidString] else { return 0 }
        return list.reduce(0) { $0 + (set.contains($1.id) ? 1 : 0) }
    }

    func toggleFav(_ c: Channel) {
        guard let p = current else { return }
        var set = favs[p.id.uuidString] ?? []
        if set.contains(c.id) { set.remove(c.id) } else { set.insert(c.id) }
        favs[p.id.uuidString] = set
        saveFavs()
    }

    private func saveFavs() {
        d.set(favs.mapValues { Array($0) }, forKey: "favs")
    }
}
