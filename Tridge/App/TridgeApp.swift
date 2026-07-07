import SwiftUI
import SwiftData

@main
struct TridgeApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .modelContainer(for: FridgeItem.self)
    }
}
