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

/// Saved playlists, the one in use, favorites, history, hidden / locked categories and account info.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var currentIndex = -1
    @Published var account: AccountInfo?
    @Published private(set) var reloadToken = UUID()
    @Published private var favs: [String: Set<String>] = [:]
    @Published private var history: [String: [String]] = [:]
    @Published private var hidden: [String: Set<String>] = [:]
    @Published private var locked: [String: Set<String>] = [:]
    @Published private(set) var pin: String = ""
    /// Continue watching: "movie:id" / "ep:id" -> [time ms, length ms, saved at]
    @Published private var positions: [String: [Double]] = [:]
    /// Last episode watched per series: seriesId -> [episode id, saved at]
    @Published private var lastEp: [String: [String]] = [:]
    /// Category order picked with press-and-hold: "<playlist><kind>" -> category ids
    @Published private var catOrder: [String: [String]] = [:]
    /// PIN entered this session: locked categories open.
    @Published var unlocked = false

    private let d = UserDefaults.standard

    init() {
        if let data = d.data(forKey: "playlists"),
           let list = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = list
        }
        currentIndex = d.object(forKey: "current") as? Int ?? -1
        favs = Store.loadSets(d, "favs")
        hidden = Store.loadSets(d, "hidden")
        locked = Store.loadSets(d, "locked")
        history = d.dictionary(forKey: "history") as? [String: [String]] ?? [:]
        pin = d.string(forKey: "pin") ?? ""
        positions = d.dictionary(forKey: "positions") as? [String: [Double]] ?? [:]
        lastEp = d.dictionary(forKey: "lastEp") as? [String: [String]] ?? [:]
        catOrder = d.dictionary(forKey: "catOrder") as? [String: [String]] ?? [:]
    }

    private static func loadSets(_ d: UserDefaults, _ key: String) -> [String: Set<String>] {
        (d.dictionary(forKey: key) as? [String: [String]] ?? [:]).mapValues { Set($0) }
    }

    private func saveSets(_ v: [String: Set<String>], _ key: String) {
        d.set(v.mapValues { Array($0) }, forKey: key)
    }

    var current: Playlist? {
        playlists.indices.contains(currentIndex) ? playlists[currentIndex] : nil
    }

    var api: Xtream? { current.map { Xtream(playlist: $0) } }

    private var pid: String { current?.id.uuidString ?? "" }

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
        reload(fresh: false)
        self.account = account
    }

    func select(_ i: Int) {
        currentIndex = i
        save()
        reload(fresh: false)
    }

    func remove(_ i: Int) {
        guard playlists.indices.contains(i) else { return }
        let gone = playlists.remove(at: i)
        let gid = gone.id.uuidString
        for k in favs.keys where k.hasPrefix(gid) { favs[k] = nil }
        favs[gid] = nil
        saveSets(favs, "favs")
        if currentIndex == i { currentIndex = -1 } else if currentIndex > i { currentIndex -= 1 }
        save()
        reload(fresh: false)
    }

    /// Reload: fresh lists from the server (fresh = also forget the lists saved on the phone).
    func reload(fresh: Bool = true) {
        Xtream.clearCache()
        if fresh { Xtream.clearDisk() }
        EpgCache.shared.clear()
        GuideCache.shared.clear()
        account = nil
        reloadToken = UUID()
    }

    func refreshAccount() async {
        guard let api else { return }
        if let a = try? await api.login() { account = a }
    }

    // MARK: favorites (live channels use the channel id; movies / series use "movie:id" / "series:id")

    func isFav(_ key: String) -> Bool { favs[pid]?.contains(key) ?? false }
    func isFav(_ c: Channel) -> Bool { isFav(c.id) }

    func favCount(in list: [Channel]) -> Int {
        guard let set = favs[pid] else { return 0 }
        return list.reduce(0) { $0 + (set.contains($1.id) ? 1 : 0) }
    }

    func toggleFav(_ key: String) {
        guard current != nil else { return }
        var set = favs[pid] ?? []
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        favs[pid] = set
        saveSets(favs, "favs")
    }

    func toggleFav(_ c: Channel) { toggleFav(c.id) }

    // MARK: history ("live", "movie", "series")

    func addHistory(_ kind: String, _ id: String) {
        let k = pid + kind
        var l = history[k] ?? []
        l.removeAll { $0 == id }
        l.insert(id, at: 0)
        history[k] = Array(l.prefix(30))
        d.set(history, forKey: "history")
    }

    func historyIds(_ kind: String) -> [String] { history[pid + kind] ?? [] }

    var historyCount: Int {
        ["live", "movie", "series"].reduce(0) { $0 + (history[pid + $1]?.count ?? 0) }
    }

    func clearHistory() {
        for k in ["live", "movie", "series"] { history[pid + k] = nil }
        d.set(history, forKey: "history")
        for k in positions.keys where k.hasPrefix(pid) { positions[k] = nil }
        for k in lastEp.keys where k.hasPrefix(pid) { lastEp[k] = nil }
        d.set(positions, forKey: "positions")
        d.set(lastEp, forKey: "lastEp")
    }

    // MARK: category order (press and hold a category, like the Android app)

    /// Puts categories in the saved order; categories not moved yet keep their place after them.
    func ordered(_ kind: String, _ cats: [Category]) -> [Category] {
        guard let order = catOrder[pid + kind], !order.isEmpty else { return cats }
        let pos = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return cats.enumerated().sorted { a, b in
            switch (pos[a.element.id], pos[b.element.id]) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }
        .map(\.element)
    }

    func moveCategory(_ kind: String, _ id: String, _ how: CatMove, current: [Category]) {
        if how == .reset {
            catOrder[pid + kind] = nil
        } else {
            var ids = current.map(\.id)
            guard let i = ids.firstIndex(of: id) else { return }
            ids.remove(at: i)
            let to: Int
            switch how {
            case .top: to = 0
            case .up: to = max(0, i - 1)
            default: to = min(ids.count, i + 1)
            }
            ids.insert(id, at: to)
            catOrder[pid + kind] = ids
        }
        d.set(catOrder, forKey: "catOrder")
    }

    // MARK: continue watching

    func savePosition(_ key: String, time: Double, length: Double) {
        guard length > 0 else { return }
        let f = time / length
        if time < 15000 && f < 0.02 { return }
        if f > 0.95 { positions[pid + key] = nil } else { positions[pid + key] = [time, length, Date().timeIntervalSince1970] }
        d.set(positions, forKey: "positions")
    }

    /// 0...1 watched, or 0 if not started / finished.
    func progress(_ key: String) -> Double {
        guard let v = positions[pid + key], v.count >= 2, v[1] > 0 else { return 0 }
        return v[0] / v[1]
    }

    func positionText(_ key: String) -> String {
        guard let v = positions[pid + key], v.count >= 2 else { return "" }
        return PlayerView.clock(v[0])
    }

    func savedAt(_ key: String) -> Double { positions[pid + key].flatMap { $0.count > 2 ? $0[2] : nil } ?? 0 }

    func setLastEpisode(_ seriesId: String, _ epId: String) {
        lastEp[pid + seriesId] = [epId, String(Date().timeIntervalSince1970)]
        d.set(lastEp, forKey: "lastEp")
    }

    func lastEpisode(_ seriesId: String) -> String? { lastEp[pid + seriesId]?.first }
    func lastEpisodeAt(_ seriesId: String) -> Double { Double(lastEp[pid + seriesId]?.last ?? "") ?? 0 }

    // MARK: hidden / locked categories ("live", "movie", "series")

    func hiddenSet(_ kind: String) -> Set<String> { hidden[pid + kind] ?? [] }

    func setHidden(_ kind: String, _ s: Set<String>) {
        hidden[pid + kind] = s
        saveSets(hidden, "hidden")
    }

    var hiddenCount: Int { ["live", "movie", "series"].reduce(0) { $0 + hiddenSet($1).count } }

    func lockedSet(_ kind: String) -> Set<String> { locked[pid + kind] ?? [] }

    func setLocked(_ kind: String, _ s: Set<String>) {
        locked[pid + kind] = s
        saveSets(locked, "locked")
    }

    var parentalOn: Bool { !pin.isEmpty }

    /// Locked and the PIN not entered yet this session.
    func isLocked(_ kind: String, _ catId: String) -> Bool {
        parentalOn && !unlocked && lockedSet(kind).contains(catId)
    }

    func checkPin(_ p: String) -> Bool { !pin.isEmpty && p == pin }

    func setPin(_ p: String) {
        pin = p
        d.set(p, forKey: "pin")
        unlocked = false
    }
}

/// Asks for the parental PIN, then runs `onOK`.
struct PinPrompt: ViewModifier {
    @EnvironmentObject var store: Store
    @Binding var show: Bool
    var message = "This category is locked."
    var onOK: () -> Void
    @State private var pin = ""
    @State private var wrong = false

    func body(content: Content) -> some View {
        content
            .alert("Enter PIN", isPresented: $show) {
                SecureField("PIN", text: $pin).keyboardType(.numberPad)
                Button("Cancel", role: .cancel) { pin = "" }
                Button("OK") {
                    if store.checkPin(pin) {
                        store.unlocked = true
                        onOK()
                    } else {
                        wrong = true
                    }
                    pin = ""
                }
            } message: {
                Text(message)
            }
            .background(
                Color.clear.alert("Wrong PIN", isPresented: $wrong) {
                    Button("OK", role: .cancel) {}
                }
            )
    }
}

extension View {
    func pinPrompt(_ show: Binding<Bool>, message: String = "This category is locked.", onOK: @escaping () -> Void) -> some View {
        modifier(PinPrompt(show: show, message: message, onOK: onOK))
    }
}


enum CatMove { case top, up, down, reset }

/// Press and hold a category: Move to Top / Move Up / Move Down / Reset Order (same as the Android app).
struct CategoryMoveMenu: ViewModifier {
    let enabled: Bool
    let move: (CatMove) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu {
                Button { move(.top) } label: { Label("Move to Top", systemImage: "arrow.up.to.line") }
                Button { move(.up) } label: { Label("Move Up", systemImage: "arrow.up") }
                Button { move(.down) } label: { Label("Move Down", systemImage: "arrow.down") }
                Divider()
                Button(role: .destructive) { move(.reset) } label: { Label("Reset Order", systemImage: "arrow.counterclockwise") }
            }
        } else {
            content
        }
    }
}
