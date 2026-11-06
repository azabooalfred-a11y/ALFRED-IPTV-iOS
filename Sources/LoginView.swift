import SwiftUI

/// Login — sample B: logo in the corner, form on a glass card.
struct LoginView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var canClose = false

    @State private var mode = 0   // 0 = Xtream Codes, 1 = M3U URL
    @State private var name = ""
    @State private var server = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var m3u = ""
    @State private var showPass = false
    @State private var busy = false
    @State private var errText: String?

    var body: some View {
        GeometryReader { g in
            let land = isLandscape(g)
            ZStack {
                Wallpaper(style: .spot)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: land ? 10 : 22) {
                        HStack(spacing: 12) {
                            if canClose { CircleButton(icon: "chevron.left", size: 40) { dismiss() } }
                            Brand(size: 40)
                            Spacer()
                        }
                        card(land)
                    }
                    .padding(.horizontal, land ? 24 : 16)
                    .padding(.top, land ? 10 : 20)
                    .padding(.bottom, 20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var seg: some View {
        HStack(spacing: 0) {
            segButton("Xtream Codes", 0)
            segButton("M3U URL", 1)
        }
        .padding(4)
        .background(T.field)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func segButton(_ title: String, _ i: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { mode = i; errText = nil }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: mode == i ? .bold : .regular))
                .foregroundColor(mode == i ? .white : T.dim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(mode == i ? T.accent : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    private func card(_ land: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Add playlist").font(.system(size: land ? 20 : 22, weight: .heavy))
                Spacer()
                if land { seg.frame(width: 260) }
            }
            if !land {
                Text(mode == 0 ? "Sign in with your Xtream Codes details" : "Paste the full M3U / M3U8 link from your provider")
                    .font(.system(size: 13))
                    .foregroundColor(T.dim)
                seg.padding(.vertical, 4)
            }
            fields(land)
            if let errText {
                Text(errText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: 0xFF7A90))
            }
            Button(action: signIn) {
                ZStack {
                    if busy { ProgressView().tint(.white) } else { Text("Sign in").font(.system(size: 16, weight: .heavy)) }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, land ? 11 : 14)
                .background(LinearGradient(colors: T.live, startPoint: .leading, endPoint: .trailing))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(Press())
            .disabled(busy)
        }
        .foregroundColor(.white)
        .padding(land ? 16 : 18)
        .background(T.glass)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func fields(_ land: Bool) -> some View {
        if mode == 0 {
            if land {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible())], spacing: 9) {
                    field("Playlist name", $name)
                    field("Server URL", $server, url: true)
                    field("Username", $user)
                    passField
                }
            } else {
                VStack(spacing: 9) {
                    field("Playlist name (e.g. Home, Sports)", $name)
                    field("Server URL (e.g. http://example.com:8080)", $server, url: true)
                    field("Username", $user)
                    passField
                }
            }
        } else {
            VStack(spacing: 9) {
                field("Playlist name (e.g. Home, Sports)", $name)
                field("M3U link (http://…/get.php?…&type=m3u_plus)", $m3u, url: true)
            }
        }
    }

    private func field(_ ph: String, _ text: Binding<String>, url: Bool = false) -> some View {
        TextField("", text: text, prompt: Text(ph).foregroundColor(T.dim))
            .keyboardType(url ? .URL : .default)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .modifier(FieldStyle())
    }

    private var passField: some View {
        HStack {
            Group {
                if showPass {
                    TextField("", text: $pass, prompt: Text("Password").foregroundColor(T.dim))
                } else {
                    SecureField("", text: $pass, prompt: Text("Password").foregroundColor(T.dim))
                }
            }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            Button { showPass.toggle() } label: {
                Image(systemName: showPass ? "eye.slash" : "eye").foregroundColor(T.dim)
            }
        }
        .modifier(FieldStyle())
    }

    private func signIn() {
        errText = nil
        let p: Playlist
        if mode == 0 {
            guard !server.trimmed.isEmpty, !user.trimmed.isEmpty, !pass.trimmed.isEmpty else {
                errText = "Fill in the server URL, username and password."
                return
            }
            p = Playlist(name: name.trimmed, base: Xtream.normalize(server), user: user.trimmed, pass: pass.trimmed, m3u: "")
        } else {
            var link = m3u.trimmed
            guard !link.isEmpty else {
                errText = "Paste your M3U link."
                return
            }
            if !link.hasPrefix("http://") && !link.hasPrefix("https://") { link = "http://" + link }
            p = Playlist(name: name.trimmed, base: link, user: "", pass: "", m3u: link)
        }
        busy = true
        Task {
            do {
                let acc = try await Xtream(playlist: p).login()
                store.add(p, account: acc)
                if canClose { dismiss() }
            } catch {
                errText = error.localizedDescription
            }
            busy = false
        }
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 14))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(T.field)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct PlaylistsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section("Saved playlists") {
                    ForEach(Array(store.playlists.enumerated()), id: \.element.id) { i, p in
                        Button {
                            store.select(i)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(p.name).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                                    Text(p.isM3u ? "M3U link" : p.base).font(.caption).foregroundColor(T.dim).lineLimit(1)
                                }
                                Spacer()
                                if i == store.currentIndex {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(T.cyan)
                                }
                            }
                        }
                    }
                    .onDelete { set in
                        for i in set.sorted(by: >) { store.remove(i) }
                    }
                }
                Section {
                    Button { adding = true } label: {
                        Label("Add playlist", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fullScreenCover(isPresented: $adding) {
                LoginView(canClose: true).environmentObject(store)
            }
        }
    }
}
