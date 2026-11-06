import SwiftUI
import UIKit

struct UpdateInfo: Decodable, Identifiable {
    let version: String
    let build: Int
    let notes: [String]?
    var id: Int { build }
}

/// Checks GitHub for a newer build; installing goes through SideStore (or AltStore).
enum Updater {
    static let infoURL = URL(string: "https://github.com/azabooalfred-a11y/ALFRED-IPTV-iOS/releases/download/latest/version.json")!
    static let ipaURL = "https://github.com/azabooalfred-a11y/ALFRED-IPTV-iOS/releases/download/latest/ALFRED-IPTV.ipa"
    static var checkedThisLaunch = false

    static var currentBuild: Int { Int(Bundle.main.infoDictionary?["ALFREDBuild"] as? String ?? "0") ?? 0 }
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    /// The newer version, or nil when this one is the latest (or GitHub can't be reached).
    static func check() async -> UpdateInfo? {
        let req = URLRequest(url: infoURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        guard let res = try? await URLSession.shared.data(for: req),
              let info = try? JSONDecoder().decode(UpdateInfo.self, from: res.0) else { return nil }
        return info.build > currentBuild ? info : nil
    }

    static func install() {
        let enc = ipaURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ipaURL
        let urls = ["sidestore://install?url=\(enc)", "altstore://install?url=\(enc)"].compactMap { URL(string: $0) }
        open(urls)
    }

    private static func open(_ list: [URL]) {
        guard let first = list.first else {
            if let u = URL(string: ipaURL) { UIApplication.shared.open(u) }
            return
        }
        UIApplication.shared.open(first, options: [:]) { ok in
            if !ok { open(Array(list.dropFirst())) }
        }
    }
}

/// Update — sample A: box in the middle with what's new.
struct UpdateBox: View {
    let info: UpdateInfo
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture(perform: close)
            VStack(spacing: 8) {
                Image("Logo").resizable().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 14))
                Text("Update available").font(.system(size: 19, weight: .black))
                Text("A new version of ALFRED-IPTV is ready.")
                    .font(.system(size: 13)).foregroundColor(Color(hex: 0xCFD6FF))
                    .multilineTextAlignment(.center)
                if let notes = info.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(notes, id: \.self) { Text("• " + $0) }
                    }
                    .font(.system(size: 12)).foregroundColor(T.dim)
                }
                Button {
                    Updater.install()
                    close()
                } label: {
                    Text("Update with SideStore")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(LinearGradient(colors: T.live, startPoint: .leading, endPoint: .trailing))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(Press())
                .padding(.top, 6)
                Button("Later", action: close)
                    .font(.system(size: 14))
                    .foregroundColor(T.dim)
                    .padding(.top, 2)
            }
            .foregroundColor(.white)
            .padding(20)
            .frame(maxWidth: 340)
            .background(Color(hex: 0x141828))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(30)
        }
    }
}
