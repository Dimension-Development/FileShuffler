import SwiftUI

@main
struct FileShufflerApp: App {
    var body: some Scene {
        WindowGroup("File Shuffler") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
