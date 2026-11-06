import SwiftUI
import UIKit
import AVFoundation

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var lock: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        URLCache.shared = URLCache(memoryCapacity: 40 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.lock
    }
}

/// Locks / rotates the screen (the player is always sideways; everything else turns freely).
enum Orientation {
    private static var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    static var isPortrait: Bool { scene?.interfaceOrientation.isPortrait ?? true }

    static func lock(_ mask: UIInterfaceOrientationMask, rotate: Bool = true) {
        AppDelegate.lock = mask
        guard let scene else { return }
        for w in scene.windows { w.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        if rotate { scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in } }
    }

    static func unlock() { lock(.allButUpsideDown, rotate: false) }
}

@main
struct ALFREDApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var started = false

    var body: some View {
        NavigationStack {
            if store.current != nil {
                HomeView()
            } else if store.playlists.isEmpty && !started {
                WelcomeView { withAnimation { started = true } }
            } else {
                LoginView(canClose: false)
            }
        }
        .tint(T.cyan)
    }
}
