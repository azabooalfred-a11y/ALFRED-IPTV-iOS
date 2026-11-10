import SwiftUI
import Combine

/// A show picked in the guide (for the info box).
struct GuidePick: Identifiable {
    let id = UUID()
    let channel: Channel
    let program: Program
    let list: [Channel]
}

private struct GuideOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// TV Guide — sample A: classic grid. Channels down the side, time across the top, pink line = now.
/// Tap a show on now to watch it; tap a later show to see what it's about.
struct GuideView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    let categories: [Category]
    let channelsFor: (String) -> [Channel]
    @State private var cat: String
    /// 0 = today, -1 = yesterday, 1 = tomorrow…
    @State private var day = 0
    @State private var hx: CGFloat = 0
    @State private var now = Date()
    @State private var picked: GuidePick?
    @State private var playing: PlayRequest?
    @AppStorage("time24") private var t24 = false

    /// Points per minute (half an hour = 120).
    private let ppm: CGFloat = 4
    private let rowH: CGFloat = 54
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    init(categories: [Category], start: String, channelsFor: @escaping (String) -> [Channel]) {
        self.categories = categories
        self.channelsFor = channelsFor
        _cat = State(initialValue: start)
    }

    private var dayStart: Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: day, to: cal.startOfDay(for: now)) ?? cal.startOfDay(for: now)
    }

    var body: some View {
        GeometryReader { g in
            let land = isLandscape(g)
            let colW: CGFloat = land ? 170 : 118
            let list = channelsFor(cat)
            ZStack {
                AppBackground()
                VStack(spacing: 8) {
                    header
                    if list.isEmpty {
                        Spacer()
                        Text("No channels here").foregroundColor(T.dim)
                        Spacer()
                    } else {
                        grid(list, colW)
                    }
                }
                .padding(.horizontal, land ? 20 : 10)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(ticker) { now = $0 }
        .alert(picked?.program.title ?? "",
               isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
               presenting: picked) { p in
            Button("Watch \(p.channel.name)") { play(p.list, p.channel) }
            Button("Close", role: .cancel) {}
        } message: { p in
            Text(timeRange(p.program) + (p.program.desc.isEmpty ? "" : "\n\n" + p.program.desc))
        }
        .fullScreenCover(item: $playing) { r in
            PlayerView(request: r).environmentObject(store)
        }
    }

    // MARK: top bar: back, title, category, day

    private var header: some View {
        HStack(spacing: 10) {
            CircleButton(icon: "chevron.left", size: 36) { dismiss() }
            Text("TV Guide").font(.system(size: 18, weight: .black)).foregroundColor(.white).lineLimit(1)
            Spacer(minLength: 6)
            Menu {
                ForEach(categories) { c in
                    Button { cat = c.id } label: {
                        if c.id == cat { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet")
                    Text(categories.first { $0.id == cat }?.name ?? "Channels").lineLimit(1)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(T.glass)
                .overlay(Capsule().stroke(Color.white.opacity(0.15)))
                .clipShape(Capsule())
                .frame(maxWidth: 220)
            }
            Menu {
                ForEach(-1...3, id: \.self) { d in
                    Button { day = d } label: {
                        if d == day { Label(dayName(d), systemImage: "checkmark") } else { Text(dayName(d)) }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(dayName(day))
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(T.accent)
                        .clipShape(Capsule())
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(T.glass)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.15)))
                }
                .foregroundColor(.white)
            }
        }
        .padding(.top, 4)
    }

    // MARK: the grid

    private func grid(_ list: [Channel], _ colW: CGFloat) -> some View {
        let start = dayStart
        let lead = colW + 4
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    timeHeader(colW, start)
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(list) { ch in
                                GuideRow(ch: ch, dayStart: start, lead: lead, colW: colW, ppm: ppm, rowH: rowH,
                                         hx: hx, now: now, t24: t24) { p in
                                    if p.start <= now && p.end > now {
                                        play(list, ch)
                                    } else {
                                        picked = GuidePick(channel: ch, program: p, list: list)
                                    }
                                } onChannel: {
                                    play(list, ch)
                                }
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }
                .frame(width: lead + 24 * 60 * ppm, alignment: .leading)
                .overlay(alignment: .topLeading) { nowLine(lead, start) }
                .background(GeometryReader { gp in
                    Color.clear.preference(key: GuideOffsetKey.self, value: -gp.frame(in: .named("guide")).minX)
                })
            }
            .coordinateSpace(name: "guide")
            .onPreferenceChange(GuideOffsetKey.self) { hx = max(0, $0) }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { scrollToNow(proxy) }
            }
            .onChange(of: day) { _ in scrollToNow(proxy) }
        }
    }

    private func timeHeader(_ colW: CGFloat, _ start: Date) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: colW + 4)
            ForEach(0..<48, id: \.self) { k in
                Text(Clock.format(start.addingTimeInterval(Double(k) * 1800), t24))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(T.dim)
                    .frame(width: 30 * ppm, alignment: .leading)
                    .id("slot\(k)")
            }
        }
        .frame(height: 20)
        .overlay(alignment: .leading) {
            Text(dayName(day))
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(T.cyan)
                .padding(.leading, 8)
                .frame(width: colW + 4, height: 20, alignment: .leading)
                .background(Color(hex: 0x081638))
                .offset(x: hx)
        }
    }

    @ViewBuilder
    private func nowLine(_ lead: CGFloat, _ start: Date) -> some View {
        let m = now.timeIntervalSince(start) / 60
        let x = lead + CGFloat(m) * ppm
        if m >= 0 && m < 1440 && x > hx + lead {
            Rectangle()
                .fill(Color(hex: 0xFF4785))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }

    // MARK: helpers

    private func scrollToNow(_ proxy: ScrollViewProxy) {
        let cal = Calendar.current
        let minutes = now.timeIntervalSince(cal.startOfDay(for: now)) / 60
        let slot = max(0, Int(minutes / 30) - 1)
        withAnimation { proxy.scrollTo("slot\(slot)", anchor: .leading) }
    }

    private func dayName(_ d: Int) -> String {
        switch d {
        case -1: return "Yesterday"
        case 0: return "Today"
        case 1: return "Tomorrow"
        default:
            let f = DateFormatter()
            f.dateFormat = "EEE d MMM"
            let date = Calendar.current.date(byAdding: .day, value: d, to: Date()) ?? Date()
            return f.string(from: date)
        }
    }

    private func timeRange(_ p: Program) -> String {
        Clock.format(p.start, t24) + " – " + Clock.format(p.end, t24)
    }

    private func play(_ list: [Channel], _ ch: Channel) {
        let api = store.api
        let items = list.map { c in
            PlayItem(id: c.id, num: c.num, title: c.name, icon: c.icon, url: api?.liveURL(c), channel: c)
        }
        let i = list.firstIndex { $0.id == ch.id } ?? 0
        playing = PlayRequest(items: items, index: i, live: true)
    }
}

/// One channel line in the guide: the channel stays on the left while the shows scroll under it.
struct GuideRow: View {
    @EnvironmentObject var store: Store
    let ch: Channel
    let dayStart: Date
    let lead: CGFloat
    let colW: CGFloat
    let ppm: CGFloat
    let rowH: CGFloat
    let hx: CGFloat
    let now: Date
    let t24: Bool
    let tap: (Program) -> Void
    let onChannel: () -> Void
    @State private var progs: [Program] = []
    @State private var loaded = false

    var body: some View {
        let dayEnd = dayStart.addingTimeInterval(86400)
        let shown = progs.filter { $0.end > dayStart && $0.start < dayEnd }
        ZStack(alignment: .topLeading) {
            if !loaded {
                ProgressView().tint(.white)
                    .frame(width: 60, height: rowH)
                    .offset(x: lead + hx)
            } else if shown.isEmpty {
                Text("No guide for this channel")
                    .font(.system(size: 13))
                    .foregroundColor(T.dim)
                    .padding(.horizontal, 12)
                    .frame(width: 260, height: rowH, alignment: .leading)
                    .background(T.field)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .offset(x: lead + hx)
            }
            ForEach(shown.indices, id: \.self) { i in
                cell(shown[i], dayEnd)
            }
            channelCell.offset(x: hx)
        }
        .frame(width: lead + 24 * 60 * ppm, height: rowH, alignment: .topLeading)
        .task(id: ch.id) {
            guard let api = store.api else {
                loaded = true
                return
            }
            let list = await GuideCache.shared.programs(api, ch)
            progs = list
            loaded = true
        }
    }

    private var channelCell: some View {
        HStack(spacing: 6) {
            Text("\(ch.num)")
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(T.cyan)
            if colW > 140 {
                LogoImage(url: ch.icon).frame(width: 30, height: 22)
            }
            Text(ch.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: colW, height: rowH)
        .background(Color(hex: 0x0E1733))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture(perform: onChannel)
    }

    private func cell(_ p: Program, _ dayEnd: Date) -> some View {
        let s = max(p.start, dayStart)
        let e = min(p.end, dayEnd)
        let x = lead + CGFloat(s.timeIntervalSince(dayStart) / 60) * ppm
        let w = max(4, CGFloat(e.timeIntervalSince(s) / 60) * ppm - 3)
        let onAir = p.start <= now && p.end > now
        let past = p.end <= now
        let bg: AnyShapeStyle = onAir
            ? AnyShapeStyle(LinearGradient(colors: T.live, startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(past ? T.field : T.accent.opacity(0.22))
        return VStack(alignment: .leading, spacing: 2) {
            Text(p.title)
                .font(.system(size: 13, weight: onAir ? .heavy : .medium))
                .lineLimit(1)
            if w > 110 {
                Text(Clock.format(p.start, t24))
                    .font(.system(size: 10.5))
                    .opacity(0.75)
            }
        }
        .foregroundColor(past ? T.dim : .white)
        .padding(.horizontal, 8)
        .frame(width: w, height: rowH, alignment: .leading)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture { tap(p) }
        .offset(x: x)
    }
}
