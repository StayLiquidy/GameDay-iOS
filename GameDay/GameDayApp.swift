import SwiftUI
import UIKit

@MainActor
final class GameDayAppDelegate: NSObject, UIApplicationDelegate {
    static var supportedOrientations: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.supportedOrientations
    }
}

@MainActor
enum AppOrientation {
    static func setPlayerActive(_ active: Bool) {
        GameDayAppDelegate.supportedOrientations = active ? .allButUpsideDown : .portrait
        updateSupportedOrientations()
        if !active { request(.portrait) }
    }

    static func toggleFullscreen(isCurrentlyLandscape: Bool) {
        GameDayAppDelegate.supportedOrientations = isCurrentlyLandscape ? .portrait : .allButUpsideDown
        updateSupportedOrientations()
        request(isCurrentlyLandscape ? .portrait : .landscapeRight)
    }

    private static func updateSupportedOrientations() {
        windowScene?.windows.first(where: \.isKeyWindow)?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        UIViewController.attemptRotationToDeviceOrientation()
    }

    private static func request(_ orientations: UIInterfaceOrientationMask) {
        windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
    }

    private static var windowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

@main
struct GameDayApp: App {
    @UIApplicationDelegateAdaptor(GameDayAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
