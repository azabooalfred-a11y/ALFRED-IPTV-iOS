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
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 180
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
        let (data, resp) = try await Xtream.session.data(from: url)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw XError("The server answered with error \(h.statusCode).")
        }
        return data
    }

    // MARK: cache (lists already downloaded this session)

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
            if live.isEmpty { throw XError("No channels found in this M3U link.") }
            return AccountInfo(username: p.name, status: "Active", expires: nil, maxConnections: "")
        }
        let data: Data
        do {
            data = try await get(api(nil))
        } catch let e as XError {
            throw e
        } catch {
            throw XError("Can't reach the server. Check the URL and your internet.")
        }
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
                               categoryId: str(o["category_id"]), directURL: ""))
        }
        cset("live", out)
        return out
    }

    private func list(_ action: String) async throws -> [[String: Any]] {
        let data: Data
        do {
            data = try await get(api(action))
        } catch let e as XError {
            throw e
        } catch {
            throw XError("Can't reach the server. Check your internet.")
        }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
    }

    func liveURL(_ c: Channel) -> URL? {
        if !c.directURL.isEmpty { return URL(string: c.directURL) }
        return URL(string: "\(base)/live/\(p.user)/\(p.pass)/\(c.id).ts")
    }

    /// Now / next programs for one channel (empty when the provider has no guide).
    func shortEpg(_ c: Channel) async -> [Program] {
        if p.isM3u { return [] }
        guard let data = try? await get(api("get_short_epg", "&stream_id=\(Xtream.enc(c.id))&limit=4")),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = o["epg_listings"] as? [[String: Any]] else { return [] }
        let now = Date()
        return arr.compactMap { e -> Program? in
            let raw = str(e["title"])
            let title = Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) } ?? raw
            guard let s = Double(str(e["start_timestamp"])), let en = Double(str(e["stop_timestamp"])) else { return nil }
            return Program(title: title, start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: en))
        }
        .filter { $0.end > now }
    }

    // MARK: M3U playlists

    private static let attr = try! NSRegularExpression(pattern: "([A-Za-z0-9_-]+)=\"([^\"]*)\"")
    private static let videoExt: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "wmv", "flv"]

    private func loadM3u() async throws {
        if let _: [Channel] = cget("live") { return }
        guard let url = URL(string: p.m3u) else { throw XError("That M3U link isn't valid.") }
        let data: Data
        do {
            data = try await get(url)
        } catch let e as XError {
            throw e
        } catch {
            throw XError("Can't download the M3U link. Check the link and your internet.")
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw XError("That link isn't an M3U playlist.")
        }
        var cats: [Category] = []
        var seen = Set<String>()
        var chans: [Channel] = []
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
            if path.contains("/series/") || path.contains("/movie/") || Xtream.videoExt.contains(ext) { return }
            let cid = "live:" + group
            if !seen.contains(cid) {
                seen.insert(cid)
                cats.append(Category(id: cid, name: group))
            }
            chans.append(Channel(id: link, num: chans.count + 1, name: name, icon: logo,
                                 categoryId: cid, directURL: link))
        }
        if !any && chans.isEmpty { throw XError("That link isn't an M3U playlist.") }
        cset("livecats", cats)
        cset("live", chans)
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
