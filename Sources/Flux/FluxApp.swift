import SwiftUI

@main
struct FluxApp: App {
    var body: some Scene {
        MenuBarExtra("Flux", systemImage: "bolt.fill") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
