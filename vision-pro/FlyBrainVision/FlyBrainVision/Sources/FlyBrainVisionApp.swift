import SwiftUI

@main
struct FlyBrainVisionApp: App {
    private static let volumeWindowID = "brain-volume"

    @State private var sceneController = BrainSceneController()
    @State private var viewerSettings = BrainViewerSettings()

    var body: some Scene {
        WindowGroup(id: "main") {
            BrainControlWindowView(
                volumeWindowID: Self.volumeWindowID,
                sceneController: sceneController,
                viewerSettings: viewerSettings
            )
        }
        .defaultSize(width: 560, height: 780)

        WindowGroup(id: Self.volumeWindowID) {
            ContentView(
                sceneController: sceneController,
                viewerSettings: viewerSettings
            )
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.2, height: 0.9, depth: 0.8, in: .meters)
        .volumeWorldAlignment(.gravityAligned)
    }
}
