import SwiftUI

@main
struct FlyBrainWorldVisionApp: App {
    private static let volumeWindowID = "fly-world-volume"

    @State private var sceneController = FlyWorldSceneController()
    @State private var viewerSettings = FlyWorldViewerSettings()

    var body: some Scene {
        WindowGroup(id: "controls") {
            FlyWorldControlWindow(
                volumeWindowID: Self.volumeWindowID,
                sceneController: sceneController,
                viewerSettings: viewerSettings
            )
        }
        .defaultSize(width: 460, height: 720)

        WindowGroup(id: Self.volumeWindowID) {
            FlyWorldVolumeView(
                sceneController: sceneController,
                viewerSettings: viewerSettings
            )
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 0.90, height: 0.68, depth: 0.68, in: .meters)
        .volumeWorldAlignment(.gravityAligned)
    }
}
