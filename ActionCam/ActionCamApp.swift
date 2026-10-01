import SwiftUI

@main
struct ActionCamApp: App {
    @StateObject private var engine = CameraEngine()

    var body: some Scene {
        WindowGroup {
            CameraScreen(engine: engine)
                .preferredColorScheme(.dark)
        }
    }
}
