import SwiftUI
import AVFoundation

@main
struct AuroraPlayerApp: App {
    @StateObject private var store = Store.shared

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            SourceListView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
