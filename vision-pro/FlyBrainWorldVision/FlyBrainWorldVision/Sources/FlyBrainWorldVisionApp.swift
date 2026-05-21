import SwiftUI

@main
struct FlyBrainWorldVisionApp: App {
    static let volumeWindowID = "fly-world-volume"
    static let controlsWindowID = "controls"
    static let immersiveSpaceID = "fly-world-room"

    @State private var sceneController = FlyWorldSceneController()
    @State private var viewerSettings = FlyWorldViewerSettings()

    var body: some Scene {
        WindowGroup(id: Self.controlsWindowID) {
            FlyWorldControlWindow(
                volumeWindowID: Self.volumeWindowID,
                controlsWindowID: Self.controlsWindowID,
                immersiveSpaceID: Self.immersiveSpaceID,
                sceneController: sceneController,
                viewerSettings: viewerSettings
            )
        }
        .defaultSize(width: 460, height: 720)

#if os(visionOS)
        WindowGroup(id: Self.volumeWindowID) {
            FlyWorldVolumeView(
                sceneController: sceneController,
                controlsWindowID: Self.controlsWindowID,
                viewerSettings: viewerSettings
            )
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 0.90, height: 0.68, depth: 0.68, in: .meters)
        .volumeWorldAlignment(.gravityAligned)

        ImmersiveSpace(id: Self.immersiveSpaceID) {
            FlyWorldImmersiveView(
                sceneController: sceneController,
                viewerSettings: viewerSettings
            )
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
#else
        WindowGroup(id: Self.volumeWindowID) {
            FlyWorldVolumeView(
                sceneController: sceneController,
                controlsWindowID: Self.controlsWindowID,
                viewerSettings: viewerSettings
            )
        }
        .defaultSize(width: 1000, height: 760)
#endif
    }
}
