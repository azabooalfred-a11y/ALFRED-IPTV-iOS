import Foundation

struct Category: Identifiable, Hashable {
    let id: String
    let name: String
}

struct Channel: Identifiable, Hashable {
    let id: String
    let num: Int
    let name: String
    let icon: String
    let categoryId: String
    /// Full link for M3U playlists ("" for Xtream Codes).
    let directURL: String
    /// The provider keeps past shows for this channel (catch-up), and for how many days.
    var archive = false
    var archiveDays = 0
}

enum Kind: String, Hashable {
    case movie, series
    var title: String { self == .movie ? "Movies" : "Series" }
}

/// A movie or a series in the lists.
struct VodItem: Identifiable, Hashable {
    let id: String
    let kind: Kind
    let name: String
    let cover: String
    let rating: String
    let categoryId: String
    let ext: String
    let added: Double
    let directURL: String

    var favKey: String { kind.rawValue + ":" + id }
}

struct Episode: Identifiable, Hashable {
    let id: String
    let season: Int
    let num: Int
    let title: String
    let ext: String
    let duration: String
    let image: String
}

struct VodDetails {
    var plot = ""
    var cast = ""
    var genre = ""
    var year = ""
    var duration = ""
    var ext = ""
    var seasons: [Int] = []
    var episodes: [Int: [Episode]] = [:]
}

struct AccountInfo {
    var username: String
    var status: String
    var expires: Date?
    var maxConnections: String
}

struct Program {
    let title: String
    let start: Date
    let end: Date
    var desc: String = ""
}

struct XError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Any JSON value as text (servers send numbers as strings and the other way round).
func str(_ v: Any?) -> String {
    switch v {
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    default: return ""
    }
}

/// Xtream Codes API client (and M3U playlists, read into the same lists).
final class Xtream {
    static let userAgent = "ALFRED-IPTV/1.0 (iPhone; iOS)"

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.timeoutIntervalForResource = 300
        c.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: c)
    }()

    let p: Playlist
    let base: String

    init(playlist: Playlist) {
        p = playlist
        base = playlist.isM3u ? playlist.m3u : Xtream.normalize(playlist.base)
    }

    /// "example.com:8080/" or ".../player_api.php?..." or ".../get.php?..." -> "http://example.com:8080"
    static func normalize(_ input: String) -> String {
        var s = input.trimmed
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        for tail in ["/player_api.php", "/get.php", "/xmltv.php"] where s.hasSuffix(tail) {
            s = String(s.dropLast(tail.count))
        }
        while s.hasSuffix("/") { s.removeLast() }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "http://" + s }
        return s
    }

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    private func api(_ action: String?, _ extra: String = "") -> URL? {
        var s = "\(base)/player_api.php?username=\(Xtream.enc(p.user))&password=\(Xtream.enc(p.pass))"
        if let action { s += "&action=\(action)" }
        return URL(string: s + extra)
    }

    private func get(_ url: URL?) async throws -> Data {
        guard let url else { throw XError("That server URL isn't valid.") }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await Xtream.session.data(from: url)
        } catch {
            if (error as? URLError)?.code == .cancelled { throw error }
            throw XError("Can't reach the server. Check the URL and your internet.")
        }
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw XError("The server answered with error \(h.statusCode).")
        }
        return data
    }

    // MARK: lists saved on the phone (Settings → Playlist Refresh)

    static let refreshDays = [0, 1, 2, 7]

    static var cacheDir: URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("lists")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func clearDisk() {
        try? FileManager.default.removeItem(at: cacheDir)
    }

    private func cachedGet(_ url: URL?, file: String) async throws -> Data {
        let f = Xtream.cacheDir.appendingPathComponent("\(p.id.uuidString)_\(file).json")
        let idx = UserDefaults.standard.object(forKey: "refreshIdx") as? Int ?? 1
        let days = Xtream.refreshDays[min(3, max(0, idx))]
        if days > 0,
           let a = try? FileManager.default.attributesOfItem(atPath: f.path),
           let m = a[.modificationDate] as? Date,
           Date().timeIntervalSince(m) < Double(days) * 86400,
           let d = try? Data(contentsOf: f), !d.isEmpty {
            return d
        }
        do {
            let d = try await get(url)
            try? d.write(to: f, options: .atomic)
            return d
        } catch {
            if let d = try? Data(contentsOf: f), !d.isEmpty { return d }   // no internet: last saved list
            throw error
        }
    }

    // MARK: memory cache (this session)

    private static var cache: [String: Any] = [:]
    private static let lock = NSLock()

    static func clearCache() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    private func cget<V>(_ key: String) -> V? {
        Xtream.lock.lock(); defer { Xtream.lock.unlock() }
        return Xtream.cache[p.id.uuidString + key] as? V
    }

    private func cset(_ key: String, _ value: Any) {
        Xtream.lock.lock(); Xtream.cache[p.id.uuidString + key] = value; Xtream.lock.unlock()
    }

    // MARK: login

    func login() async throws -> AccountInfo {
        if p.isM3u {
            try await loadM3u()
            let live: [Channel] = cget("live") ?? []
            let mv: [VodItem] = cget("items_movie") ?? []
            let se: [VodItem] = cget("items_series") ?? []
            if live.isEmpty && mv.isEmpty && se.isEmpty { throw XError("No channels found in this M3U link.") }
            return AccountInfo(username: p.name, status: "Active", expires: nil, maxConnections: "")
        }
        let data = try await get(api(nil))
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw XError("The server didn't answer like an Xtream Codes server. Check the URL.")
        }
        guard let info = o["user_info"] as? [String: Any], str(info["auth"]) == "1" else {
            throw XError("Wrong username or password.")
        }
        let status = str(info["status"]).isEmpty ? "Active" : str(info["status"])
        if status.lowercased() != "active" { throw XError("Account status: \(status)") }
        var exp: Date?
        if let t = Double(str(info["exp_date"])), t > 0 { exp = Date(timeIntervalSince1970: t) }
        return AccountInfo(username: str(info["username"]), status: status, expires: exp,
                           maxConnections: str(info["max_connections"]))
    }

    private func list(_ action: String) async throws -> [[String: Any]] {
        let data = try await cachedGet(api(action), file: action)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
    }

    // MARK: live TV

    func liveCategories() async throws -> [Category] {
        if let hit: [Category] = cget("livecats") { return hit }
        if p.isM3u {
            try await loadM3u()
            return cget("livecats") ?? []
        }
        let arr = try await list("get_live_categories")
        let cats = arr.map { Category(id: str($0["category_id"]), name: str($0["category_name"])) }
        cset("livecats", cats)
        return cats
    }

    func liveStreams() async throws -> [Channel] {
        if let hit: [Channel] = cget("live") { return hit }
        if p.isM3u {
            try await loadM3u()
            return cget("live") ?? []
        }
        let arr = try await list("get_live_streams")
        var out: [Channel] = []
        out.reserveCapacity(arr.count)
        for (i, o) in arr.enumerated() {
            out.append(Channel(id: str(o["stream_id"]), num: Int(str(o["num"])) ?? i + 1,
                               name: str(o["name"]), icon: str(o["stream_icon"]),
                               categoryId: str(o["category_id"]), directURL: "",
                               archive: str(o["tv_archive"]) == "1",
                               archiveDays: Int(str(o["tv_archive_duration"])) ?? 0))
        }
        cset("live", out)
        return out
    }

    /// Settings → Live Stream Format: 0 = TS, 1 = HLS (m3u8).
    func liveURL(_ c: Channel) -> URL? {
        if !c.directURL.isEmpty { return URL(string: c.directURL) }
        let hls = UserDefaults.standard.integer(forKey: "liveFormat") == 1
        return URL(string: "\(base)/live/\(p.user)/\(p.pass)/\(c.id).\(hls ? "m3u8" : "ts")")
    }

    // MARK: catch-up (rewind live TV)

    private static var tzCache: [String: TimeZone] = [:]

    /// The server's own time zone (catch-up start times are in the server's local time).
    func serverTimeZone() async -> TimeZone {
        Xtream.lock.lock(); let hit = Xtream.tzCache[base]; Xtream.lock.unlock()
        if let hit { return hit }
        var tz = TimeZone.current
        if let data = try? await get(api(nil)),
           let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let si = o["server_info"] as? [String: Any],
           let z = TimeZone(identifier: str(si["timezone"])) {
            tz = z
        }
        Xtream.lock.lock(); Xtream.tzCache[base] = tz; Xtream.lock.unlock()
        return tz
    }

    /// Link that plays a channel from an earlier time (catch-up).
    func timeshiftURL(_ c: Channel, start: Date, minutes: Int, tz: TimeZone) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd:HH-mm"
        return URL(string: "\(base)/timeshift/\(p.user)/\(p.pass)/\(max(1, minutes))/\(f.string(from: start))/\(c.id).ts")
    }

    /// Now / next programs for one channel (empty when the provider has no guide).
    func shortEpg(_ c: Channel) async -> [Program] {
        if p.isM3u { return [] }
        guard let data = try? await get(api("get_short_epg", "&stream_id=\(Xtream.enc(c.id))&limit=4")),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = o["epg_listings"] as? [[String: Any]] else { return [] }
        let now = Date()
        return arr.compactMap(Xtream.program).filter { $0.end > now }
    }

    /// The whole guide for one channel (usually several days) for the TV Guide.
    func fullEpg(_ c: Channel) async -> [Program] {
        if p.isM3u { return [] }
        var list: [Program] = []
        if let data = try? await get(api("get_simple_data_table", "&stream_id=\(Xtream.enc(c.id))")),
           let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let arr = o["epg_listings"] as? [[String: Any]] {
            var seen = Set<Double>()
            for e in arr {
                guard let pr = Xtream.program(e), !seen.contains(pr.start.timeIntervalSince1970) else { continue }
                seen.insert(pr.start.timeIntervalSince1970)
                list.append(pr)
            }
        }
        if list.isEmpty {
            let short = await shortEpg(c)
            return short
        }
        return list.sorted { $0.start < $1.start }
    }

    /// Guide titles and descriptions come base64-encoded.
    private static func text(_ v: Any?) -> String {
        let raw = str(v)
        return Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) } ?? raw
    }

    static func program(_ e: [String: Any]) -> Program? {
        guard let s = Double(str(e["start_timestamp"])), let en = Double(str(e["stop_timestamp"])), en > s else { return nil }
        return Program(title: text(e["title"]), start: Date(timeIntervalSince1970: s),
                       end: Date(timeIntervalSince1970: en), desc: text(e["description"]))
    }

    // MARK: movies & series

    func categories(_ k: Kind) async throws -> [Category] {
        if let hit: [Category] = cget("cats_" + k.rawValue) { return hit }
        if p.isM3u {
            try await loadM3u()
            return cget("cats_" + k.rawValue) ?? []
        }
        let arr = try await list(k == .movie ? "get_vod_categories" : "get_series_categories")
        let cats = arr.map { Category(id: str($0["category_id"]), name: str($0["category_name"])) }
        cset("cats_" + k.rawValue, cats)
        return cats
    }

    func items(_ k: Kind) async throws -> [VodItem] {
        if let hit: [VodItem] = cget("items_" + k.rawValue) { return hit }
        if p.isM3u {
            try await loadM3u()
            return cget("items_" + k.rawValue) ?? []
        }
        let arr = try await list(k == .movie ? "get_vod_streams" : "get_series")
        var out: [VodItem] = []
        out.reserveCapacity(arr.count)
        for o in arr {
            let id = str(k == .movie ? o["stream_id"] : o["series_id"])
            if id.isEmpty { continue }
            var rating = str(o["rating"])
            if let r = Double(rating) { rating = r > 0 ? String(format: "%.1f", r) : "" }
            out.append(VodItem(id: id, kind: k, name: str(o["name"]),
                               cover: str(k == .movie ? o["stream_icon"] : o["cover"]),
                               rating: rating, categoryId: str(o["category_id"]),
                               ext: str(o["container_extension"]),
                               added: Double(str(k == .movie ? o["added"] : o["last_modified"])) ?? 0,
                               directURL: ""))
        }
        cset("items_" + k.rawValue, out)
        return out
    }

    func details(_ it: VodItem) async -> VodDetails {
        var d = VodDetails()
        if !it.directURL.isEmpty || p.isM3u { return d }
        let url = it.kind == .movie
            ? api("get_vod_info", "&vod_id=\(Xtream.enc(it.id))")
            : api("get_series_info", "&series_id=\(Xtream.enc(it.id))")
        guard let data = try? await get(url),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return d }
        let info = o["info"] as? [String: Any] ?? [:]
        d.plot = str(info["plot"]).isEmpty ? str(info["description"]) : str(info["plot"])
        d.cast = str(info["cast"]).isEmpty ? str(info["actors"]) : str(info["cast"])
        d.genre = str(info["genre"])
        let rel = str(info["releasedate"]).isEmpty ? str(info["releaseDate"]) : str(info["releasedate"])
        d.year = String(rel.prefix(4))
        d.duration = str(info["duration"])
        if let md = o["movie_data"] as? [String: Any] { d.ext = str(md["container_extension"]) }
        if it.kind == .series {
            var eps: [Int: [Episode]] = [:]
            func add(_ season: Int, _ list: [[String: Any]]) {
                eps[season] = list.enumerated().map { i, e in
                    let ei = e["info"] as? [String: Any] ?? [:]
                    return Episode(id: str(e["id"]), season: season, num: Int(str(e["episode_num"])) ?? i + 1,
                                   title: str(e["title"]), ext: str(e["container_extension"]),
                                   duration: str(ei["duration"]), image: str(ei["movie_image"]))
                }
            }
            if let dict = o["episodes"] as? [String: Any] {
                for (k, v) in dict { if let s = Int(k), let l = v as? [[String: Any]] { add(s, l) } }
            } else if let arr = o["episodes"] as? [Any] {
                for (i, v) in arr.enumerated() {
                    if let l = v as? [[String: Any]] {
                        add(Int(str(l.first?["season"])) ?? i + 1, l)
                    }
                }
            }
            d.episodes = eps
            d.seasons = eps.keys.sorted()
        }
        return d
    }

    func movieURL(_ it: VodItem, ext: String = "") -> URL? {
        if !it.directURL.isEmpty { return URL(string: it.directURL) }
        let e = !ext.isEmpty ? ext : (it.ext.isEmpty ? "mp4" : it.ext)
        return URL(string: "\(base)/movie/\(p.user)/\(p.pass)/\(it.id).\(e)")
    }

    func episodeURL(_ e: Episode) -> URL? {
        URL(string: "\(base)/series/\(p.user)/\(p.pass)/\(e.id).\(e.ext.isEmpty ? "mp4" : e.ext)")
    }

    // MARK: M3U playlists
    // Groups become categories; /movie/ links (or .mp4 / .mkv files) go to Movies, /series/ links to Series, the rest is Live TV.

    private static let attr = try! NSRegularExpression(pattern: "([A-Za-z0-9_-]+)=\"([^\"]*)\"")
    private static let videoExt: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "wmv", "flv"]

    private func loadM3u() async throws {
        if let _: [Channel] = cget("live") { return }
        guard let url = URL(string: p.m3u) else { throw XError("That M3U link isn't valid.") }
        let data = try await cachedGet(url, file: "m3u")
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw XError("That link isn't an M3U playlist.")
        }
        var liveCats: [Category] = [], mvCats: [Category] = [], seCats: [Category] = []
        var seen = Set<String>()
        var chans: [Channel] = []
        var movies: [VodItem] = [], series: [VodItem] = []
        var info: String?
        var any = false
        text.enumerateLines { raw, _ in
            let line = raw.trimmed
            if line.isEmpty { return }
            if line.hasPrefix("#EXTM3U") { any = true; return }
            if line.hasPrefix("#EXTINF") { info = line; any = true; return }
            if line.hasPrefix("#") { return }
            let link = line
            var name = link, logo = "", group = ""
            if let inf = info {
                let ns = inf as NSString
                for m in Xtream.attr.matches(in: inf, range: NSRange(location: 0, length: ns.length)) {
                    let k = ns.substring(with: m.range(at: 1)).lowercased()
                    let v = ns.substring(with: m.range(at: 2))
                    switch k {
                    case "tvg-logo": logo = v
                    case "group-title": group = v
                    case "tvg-name": if name == link { name = v }
                    default: break
                    }
                }
                let r = inf.range(of: "\",", options: .backwards).map { inf.index(after: $0.lowerBound) }
                    ?? inf.firstIndex(of: ",")
                if let r {
                    let t = String(inf[inf.index(after: r)...]).trimmed
                    if !t.isEmpty { name = t }
                }
            }
            info = nil
            if group.isEmpty { group = "Other" }
            let lower = link.lowercased()
            let path = lower.split(separator: "?").first.map(String.init) ?? lower
            let ext = (path as NSString).pathExtension
            if path.contains("/series/") || path.contains("/movie/") || Xtream.videoExt.contains(ext) {
                let k: Kind = path.contains("/series/") ? .series : .movie
                let cid = k.rawValue + ":" + group
                if !seen.contains(cid) {
                    seen.insert(cid)
                    if k == .movie { mvCats.append(Category(id: cid, name: group)) } else { seCats.append(Category(id: cid, name: group)) }
                }
                let it = VodItem(id: link, kind: k, name: name, cover: logo, rating: "", categoryId: cid,
                                 ext: ext, added: 0, directURL: link)
                if k == .movie { movies.append(it) } else { series.append(it) }
                return
            }
            let cid = "live:" + group
            if !seen.contains(cid) {
                seen.insert(cid)
                liveCats.append(Category(id: cid, name: group))
            }
            chans.append(Channel(id: link, num: chans.count + 1, name: name, icon: logo,
                                 categoryId: cid, directURL: link))
        }
        if !any && chans.isEmpty && movies.isEmpty && series.isEmpty {
            throw XError("That link isn't an M3U playlist.")
        }
        cset("livecats", liveCats)
        cset("live", chans)
        cset("cats_movie", mvCats)
        cset("items_movie", movies)
        cset("cats_series", seCats)
        cset("items_series", series)
    }
}

/// Now / next guide, kept for the session.
final class EpgCache {
    static let shared = EpgCache()
    private var map: [String: [Program]] = [:]
    private let lock = NSLock()

    func programs(_ api: Xtream, _ ch: Channel) async -> [Program] {
        lock.lock(); let hit = map[ch.id]; lock.unlock()
        if let hit, hit.isEmpty || hit[0].end > Date() { return hit }
        let list = await api.shortEpg(ch)
        if Task.isCancelled { return list }
        lock.lock(); map[ch.id] = list; lock.unlock()
        return list
    }

    func clear() {
        lock.lock(); map.removeAll(); lock.unlock()
    }
}

/// Full guide for the TV Guide, kept for the session.
final class GuideCache {
    static let shared = GuideCache()
    private var map: [String: [Program]] = [:]
    private let lock = NSLock()

    func programs(_ api: Xtream, _ ch: Channel) async -> [Program] {
        lock.lock(); let hit = map[ch.id]; lock.unlock()
        if let hit { return hit }
        let list = await api.fullEpg(ch)
        if Task.isCancelled { return list }
        lock.lock(); map[ch.id] = list; lock.unlock()
        return list
    }

    func clear() {
        lock.lock(); map.removeAll(); lock.unlock()
    }
}

/// Sort orders picked in Settings.
enum Sorts {
    static let catNames = ["Default", "A–Z", "Z–A"]
    static let chNames = ["Default", "A–Z", "Z–A", "Channel number"]
    static let vodNames = ["Default", "A–Z", "Z–A", "Recently added"]

    static func cats(_ c: [Category], _ mode: Int) -> [Category] {
        switch mode {
        case 1: return c.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case 2: return c.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        default: return c
        }
    }

    static func chans(_ c: [Channel], _ mode: Int) -> [Channel] {
        switch mode {
        case 1: return c.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case 2: return c.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case 3: return c.sorted { $0.num < $1.num }
        default: return c
        }
    }

    static func vod(_ v: [VodItem], _ mode: Int) -> [VodItem] {
        switch mode {
        case 1: return v.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case 2: return v.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case 3: return v.sorted { $0.added > $1.added }
        default: return v
        }
    }
}
