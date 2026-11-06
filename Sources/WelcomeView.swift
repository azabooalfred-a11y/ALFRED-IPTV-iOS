import SwiftUI

/// Welcome — sample A (same as Android): logo, WELCOME TO, ALFRED-IPTV, Get Started at the bottom center.
struct WelcomeView: View {
    let start: () -> Void

    var body: some View {
        GeometryReader { g in
            let land = isLandscape(g)
            ZStack {
                Wallpaper(style: .glow)
                VStack(spacing: 0) {
                    Spacer()
                    Image("Logo")
                        .resizable()
                        .frame(width: land ? 86 : 120, height: land ? 86 : 120)
                        .clipShape(RoundedRectangle(cornerRadius: land ? 20 : 28))
                        .shadow(color: Color(hex: 0x2B7BFF, a: 0.5), radius: 24)
                        .padding(.bottom, land ? 10 : 18)
                    Text("WELCOME TO")
                        .font(.system(size: 15, weight: .medium))
                        .kerning(5)
                        .foregroundColor(Color(hex: 0x9FDCFF))
                    Text("ALFRED-IPTV")
                        .font(.system(size: land ? 36 : 42, weight: .black))
                        .foregroundColor(.white)
                        .padding(.top, 2)
                    Text("Live TV, movies and series from your own playlist")
                        .font(.system(size: 15))
                        .foregroundColor(Color(hex: 0xC9D4FF))
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                        .padding(.horizontal, 30)
                    Spacer()
                    Button(action: start) {
                        Text("Get Started")
                            .font(.system(size: 19, weight: .heavy))
                            .foregroundColor(.white)
                            .frame(width: 280)
                            .padding(.vertical, land ? 14 : 17)
                            .background(LinearGradient(colors: T.live, startPoint: .leading, endPoint: .trailing))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: Color(hex: 0x2B7BFF, a: 0.45), radius: 18, y: 8)
                    }
                    .buttonStyle(Press())
                    .padding(.bottom, land ? 24 : 50)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
