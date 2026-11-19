import SwiftUI

@main
struct RouterFinderApp: App {
    @StateObject private var scanner = ScannerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scanner)
        }
    }
}
