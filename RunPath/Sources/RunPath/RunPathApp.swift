import SwiftUI

@main
struct RunPathApp: App {
    @StateObject private var storage = RouteStorage.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(storage)
        }
    }
}
