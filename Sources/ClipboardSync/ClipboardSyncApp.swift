import SwiftUI

@main
struct ClipboardSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = AppSettings()
    @StateObject private var monitor = ClipboardMonitor()
    @StateObject private var network = NetworkService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(monitor)
                .environmentObject(network)
        }
    }
}
