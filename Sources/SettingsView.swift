import SwiftUI

struct Choice: Identifiable {
    let id = UUID()
    let title: String
    let options: [String]
    let selected: Int
    let set: (Int) -> Void
}

/// Settings — sample B: grouped, colored icons (2 columns sideways).
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("liveCatSort") private var liveCatSort = 0
    @AppStorage("liveChSort") private var liveChSort = 0
    @AppStorage("vodSort") private var vodSort = 0
    @AppStorage("liveFormat") private var liveFormat = 0
    @AppStorage("time24") private var time24 = false
    @AppStorage("refreshIdx") private var refreshIdx = 1

    @State private var choice: Choice?
    @State private var showPlaylists = false
    @State private var adding = false
    @State private var hideSheet = false
    @State private var parentalSheet = false
    @State private var askPin = false
    @State private var newPin = false
    @State private var pinText = ""
    @State private var confirmHistory = false
    @State private var message: String?
    @State private var update: UpdateInfo?
    @State private var checking = false

    private static let refreshNames = ["Every time", "Every day", "Every 2 days", "Every week"]

    var body: some View {
        GeometryReader { g in
            let land = isLandscape(g)
            ZStack {
                AppBackground()
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        CircleButton(icon: "chevron.left", size: 36) { dismiss() }
                        Image("Logo").resizable().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7))
                        Text("Settings").font(.system(size: 18, weight: .black))
                        Spacer()
                        Clock(size: 16)
                    }
                    .padding(.top, 4)
                    ScrollView(showsIndicators: false) {
                        if land {
                            HStack(alignment: .top, spacing: 14) {
                                VStack(spacing: 0) { playlistGroup; liveGroup; vodGroup }
                                VStack(spacing: 0) { privacyGroup; appGroup }
                            }
                        } else {
                            VStack(spacing: 0) { playlistGroup; liveGroup; vodGroup; privacyGroup; appGroup }
                        }
                        HStack {
                            Text("Playlist: \(store.current?.name ?? "")")
                            Spacer()
                            Text("Version \(Updater.currentVersion)")
                        }
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: 0xCFD6FF))
                        .padding(.vertical, 12)
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, land ? 20 : 14)
                if let u = update { UpdateBox(info: u) { update = nil } }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog(choice?.title ?? "", isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }),
                            titleVisibility: .visible, presenting: choice) { c in
            ForEach(c.options.indices, id: \.self) { i in
                Button(c.options[i] + (i == c.selected ? "  ✓" : "")) { c.set(i) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showPlaylists) { PlaylistsView().environmentObject(store) }
        .fullScreenCover(isPresented: $adding) { LoginView(canClose: true).environmentObject(store) }
        .sheet(isPresented: $hideSheet) {
            CategoryPicker(title: "Hide Categories", mode: .hide).environmentObject(store)
        }
        .sheet(isPresented: $parentalSheet) { ParentalView().environmentObject(store) }
        .pinPrompt($askPin, message: "Enter your PIN to change Parental Control.") { parentalSheet = true }
        .alert("Set a PIN", isPresented: $newPin) {
            SecureField("4-digit PIN", text: $pinText).keyboardType(.numberPad)
            Button("Cancel", role: .cancel) { pinText = "" }
            Button("Save") {
                let p = pinText.trimmed
                pinText = ""
                if p.count >= 4 {
                    store.setPin(p)
                    parentalSheet = true
                } else {
                    message = "The PIN needs at least 4 digits."
                }
            }
        } message: {
            Text("Parental Control locks the categories you pick behind this PIN.")
        }
        .alert("Clear history?", isPresented: $confirmHistory) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { store.clearHistory() }
        } message: {
            Text("Removes the recently watched channels, movies and series.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: groups

    private var playlistGroup: some View {
        SettingsGroup(title: "Playlist") {
            SettingsRow(icon: "list.bullet", color: Color(hex: 0x4F6BFF), title: "Change Playlist",
                        value: store.current?.name ?? "") { showPlaylists = true }
            SettingsRow(icon: "plus", color: Color(hex: 0x4F6BFF), title: "Add Playlist") { adding = true }
            SettingsRow(icon: "arrow.triangle.2.circlepath", color: Color(hex: 0x2B7BFF), title: "Playlist Refresh",
                        value: SettingsView.refreshNames[min(3, max(0, refreshIdx))]) {
                choice = Choice(title: "Playlist Refresh", options: SettingsView.refreshNames, selected: refreshIdx) { refreshIdx = $0 }
            }
        }
    }

    private var liveGroup: some View {
        SettingsGroup(title: "Live TV") {
            SettingsRow(icon: "textformat.abc", color: Color(hex: 0x0BA88A), title: "Live Category Sort",
                        value: Sorts.catNames[liveCatSort]) {
                choice = Choice(title: "Live Category Sort", options: Sorts.catNames, selected: liveCatSort) { liveCatSort = $0 }
            }
            SettingsRow(icon: "textformat.abc", color: Color(hex: 0x0BA88A), title: "Live Channel Sort",
                        value: Sorts.chNames[liveChSort]) {
                choice = Choice(title: "Live Channel Sort", options: Sorts.chNames, selected: liveChSort) { liveChSort = $0 }
            }
            SettingsRow(icon: "dot.radiowaves.left.and.right", color: Color(hex: 0xFF7A1A), title: "Live Stream Format",
                        value: liveFormat == 1 ? "HLS" : "TS") {
                choice = Choice(title: "Live Stream Format", options: ["TS (MPEG-TS)", "HLS (m3u8)"], selected: liveFormat) { liveFormat = $0 }
            }
        }
    }

    private var vodGroup: some View {
        SettingsGroup(title: "Movies & Series") {
            SettingsRow(icon: "textformat.abc", color: Color(hex: 0x0BA88A), title: "VOD / Series Sort",
                        value: Sorts.vodNames[vodSort]) {
                choice = Choice(title: "VOD / Series Sort", options: Sorts.vodNames, selected: vodSort) { vodSort = $0 }
            }
        }
    }

    private var privacyGroup: some View {
        SettingsGroup(title: "Privacy") {
            SettingsRow(icon: "lock.fill", color: Color(hex: 0xFF4785), title: "Parental Control",
                        value: store.parentalOn ? "On" : "Off") {
                if store.parentalOn { askPin = true } else { newPin = true }
            }
            SettingsRow(icon: "eye.slash.fill", color: Color(hex: 0x8B3DFF), title: "Hide Categories",
                        value: store.hiddenCount == 0 ? "None" : "\(store.hiddenCount) hidden") { hideSheet = true }
            SettingsRow(icon: "trash.fill", color: Color(hex: 0xFF4785), title: "Clear History",
                        value: "\(store.historyCount) items") { confirmHistory = true }
        }
    }

    private var appGroup: some View {
        SettingsGroup(title: "App") {
            SettingsRow(icon: "clock.fill", color: Color(hex: 0xFF7A1A), title: "Time Format",
                        value: time24 ? "24h" : "12h") {
                choice = Choice(title: "Time Format", options: ["12h  (06:41 PM)", "24h  (18:41)"], selected: time24 ? 1 : 0) { time24 = $0 == 1 }
            }
            SettingsRow(icon: "paintbrush.fill", color: Color(hex: 0xFF4785), title: "Clear Cache") {
                Xtream.clearDisk()
                URLCache.shared.removeAllCachedResponses()
                store.reload()
                message = "Cache cleared. Lists will download again."
            }
            SettingsRow(icon: "arrow.up.circle.fill", color: Color(hex: 0x21D3A6), title: "Check for Updates",
                        value: checking ? "Checking…" : Updater.currentVersion) {
                checking = true
                Task {
                    let u = await Updater.check()
                    checking = false
                    if let u { update = u } else { message = "You have the latest version (\(Updater.currentVersion))." }
                }
            }
            SettingsRow(icon: "info.circle.fill", color: Color(hex: 0x8A93B8), title: "About") {
                message = "ALFRED-IPTV for iPhone \(Updater.currentVersion)\n\nThis app is a media player only. It does not include or sell any channels, movies or playlists — you add your own from your provider."
            }
        }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(1)
                .foregroundColor(T.dim)
                .padding(.leading, 14)
            VStack(spacing: 0) { content }
                .background(T.glass)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(.top, 12)
    }
}

struct SettingsRow: View {
    let icon: String
    let color: Color
    let title: String
    var value: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(title).font(.system(size: 15))
                Spacer()
                Text(value).font(.system(size: 13)).foregroundColor(T.dim).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(T.dim)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 54) }
            .contentShape(Rectangle())
        }
    }
}

/// Pick categories to hide or lock (Live / Movies / Series).
struct CategoryPicker: View {
    enum Mode { case hide, lock }
    let title: String
    let mode: Mode
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "live"
    @State private var cats: [Category] = []
    @State private var sel: Set<String> = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Live").tag("live")
                    Text("Movies").tag("movie")
                    Text("Series").tag("series")
                }
                .pickerStyle(.segmented)
                .padding()
                if loading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else {
                    List(cats) { c in
                        Button {
                            if sel.contains(c.id) { sel.remove(c.id) } else { sel.insert(c.id) }
                            save()
                        } label: {
                            HStack {
                                Text(c.name).foregroundColor(.primary)
                                Spacer()
                                if sel.contains(c.id) {
                                    Image(systemName: mode == .hide ? "eye.slash.fill" : "lock.fill")
                                        .foregroundColor(mode == .hide ? Color(hex: 0x8B3DFF) : Color(hex: 0xFF4785))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    Button(sel.isEmpty ? "Select all" : "Clear") {
                        sel = sel.isEmpty ? Set(cats.map(\.id)) : []
                        save()
                    }
                }
            }
            .task(id: tab) { await load() }
        }
    }

    private func save() {
        if mode == .hide { store.setHidden(tab, sel) } else { store.setLocked(tab, sel) }
    }

    private func load() async {
        loading = true
        sel = mode == .hide ? store.hiddenSet(tab) : store.lockedSet(tab)
        guard let api = store.api else { loading = false; return }
        switch tab {
        case "live": cats = (try? await api.liveCategories()) ?? []
        case "movie": cats = (try? await api.categories(.movie)) ?? []
        default: cats = (try? await api.categories(.series)) ?? []
        }
        loading = false
    }
}

struct ParentalView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var lockSheet = false
    @State private var changePin = false
    @State private var pinText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { lockSheet = true } label: {
                        Label("Lock Categories", systemImage: "lock.fill")
                    }
                    Button { changePin = true } label: {
                        Label("Change PIN", systemImage: "key.fill")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        for k in ["live", "movie", "series"] { store.setLocked(k, []) }
                        store.setPin("")
                        dismiss()
                    } label: {
                        Label("Turn off Parental Control", systemImage: "lock.open.fill")
                    }
                } footer: {
                    Text("Locked categories ask for the PIN before they open.")
                }
            }
            .navigationTitle("Parental Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $lockSheet) {
                CategoryPicker(title: "Lock Categories", mode: .lock).environmentObject(store)
            }
            .alert("New PIN", isPresented: $changePin) {
                SecureField("4-digit PIN", text: $pinText).keyboardType(.numberPad)
                Button("Cancel", role: .cancel) { pinText = "" }
                Button("Save") {
                    if pinText.trimmed.count >= 4 { store.setPin(pinText.trimmed) }
                    pinText = ""
                }
            }
        }
    }
}
