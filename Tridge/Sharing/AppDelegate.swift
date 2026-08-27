import CloudKit
import UIKit

/// Exists for one reason: SwiftUI's generated scene has no CloudKit invitation
/// callbacks, and returning a scene configuration is the documented way to add
/// them (Apple, *Accepting share invitations in a SwiftUI app*).
///
/// It creates no window of its own — SwiftUI still owns the interface.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil,
                                                 sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

/// The two invitation routes — a scene that is already connected, and a scene
/// being connected by the tap itself — pass the same metadata to the same
/// router, which is what makes warm and cold delivery indistinguishable
/// downstream.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        // Cold launch: the invitation is in the connection options and there
        // will never be a callback for it.
        guard let metadata = connectionOptions.cloudKitShareMetadata else { return }
        MainActor.assumeIsolated { ShareInvitationRouter.shared.receive(metadata) }
    }

    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        // Warm: the app was already running when the invitation was tapped.
        MainActor.assumeIsolated { ShareInvitationRouter.shared.receive(cloudKitShareMetadata) }
    }
}
