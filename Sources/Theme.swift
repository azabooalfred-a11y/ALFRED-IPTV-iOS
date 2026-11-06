import SwiftUI

extension Color {
    init(hex: UInt32, a: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: a)
    }
}

/// ALFRED-IPTV colors (same as the Android app).
enum T {
    static let accent = Color(hex: 0x4F6BFF)
    static let cyan = Color(hex: 0x3AD7FF)
    static let dim = Color(hex: 0x8A93B8)
    static let field = Color(hex: 0x141828, a: 0.75)
    static let glass = Color(hex: 0x141828, a: 0.6)
    static let live = [Color(hex: 0x2B7BFF), Color(hex: 0x08C6FF)]
    static let movies = [Color(hex: 0x8B3DFF), Color(hex: 0xB44BFF)]
    static let series = [Color(hex: 0x0BA88A), Color(hex: 0x21D3A6)]
    static let settings = [Color(hex: 0xFF7A1A), Color(hex: 0xFFAE4A)]
    static let reload = [Color(hex: 0xFF4785), Color(hex: 0xFF74B0)]
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x0A2156), Color(hex: 0x07143A), Color(hex: 0x040A1E)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(hex: 0x2E7BFF, a: 0.33), .clear],
                           center: UnitPoint(x: 0.15, y: 0.75), startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

struct Brand: View {
    var size: CGFloat = 40

    var body: some View {
        HStack(spacing: 10) {
            Image("Logo")
                .resizable()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            VStack(alignment: .leading, spacing: 2) {
                Text("ALFRED")
                    .font(.system(size: size * 0.55, weight: .black))
                    .kerning(0.5)
                Text("IPTV PLAYER")
                    .font(.system(size: size * 0.22, weight: .medium))
                    .kerning(size * 0.1)
                    .foregroundColor(T.cyan)
            }
        }
        .foregroundColor(.white)
    }
}

struct Clock: View {
    var size: CGFloat = 20
    @AppStorage("time24") private var t24 = false

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            Text(Clock.format(ctx.date, t24))
                .font(.system(size: size, weight: .light))
                .foregroundColor(.white)
        }
    }

    private static let f12: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
    private static let f24: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    static func format(_ d: Date, _ t24: Bool) -> String { (t24 ? f24 : f12).string(from: d) }
}

struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CircleButton: View {
    let icon: String
    var size: CGFloat = 44
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(filled ? AnyShapeStyle(T.accent) : AnyShapeStyle(T.glass))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(filled ? 0 : 0.15)))
        }
        .buttonStyle(Press())
    }
}

struct Pill: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(T.glass)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.15)))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(Press())
    }
}

struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(T.dim)
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(T.dim))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .foregroundColor(.white)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(T.dim)
                }
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(T.field)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Channel logo with a placeholder while it loads (or if there is none).
struct LogoImage: View {
    let url: String

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            if let img = phase.image {
                img.resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: 0x1C2132))
                    .overlay(Image(systemName: "tv").font(.system(size: 11)).foregroundColor(T.dim))
            }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Sideways or upright, from the screen itself (the keyboard shrinking the view must not count as "sideways").
func isLandscape(_ g: GeometryProxy) -> Bool {
    let b = UIScreen.main.bounds
    _ = g.size
    return b.width > b.height
}
