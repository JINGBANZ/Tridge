import SwiftUI
import SwiftData

@main
struct WhatsInMyFridgeApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .modelContainer(for: FridgeItem.self)
    }
}
