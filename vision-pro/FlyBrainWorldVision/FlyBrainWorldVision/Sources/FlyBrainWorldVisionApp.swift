import SwiftUI

@main
struct FlyBrainWorldVisionApp: App {
    static let volumeWindowID = "fly-world-volume"
    static let controlsWindowID = "controls"
    static let immersiveSpaceID = "fly-world-room"
    static let controlsWindowValue = FlyWorldWindowRoute.controls
    static let volumeWindowValue = FlyWorldWindowRoute.volume

    @State private var sceneController = FlyWorldSceneController()
    @State private var viewerSettings = FlyWorldViewerSettings()

    var body: some Scene {
        WindowGroup(id: Self.controlsWindowID, for: FlyWorldWindowRoute.self) { _ in
            FlyWorldControlWindow(
                volumeWindowID: Self.volumeWindowID,
                controlsWindowID: Self.controlsWindowID,
                immersiveSpaceID: Self.immersiveSpaceID,
                volumeWindowValue: Self.volumeWindowValue,
                controlsWindowValue: Self.controlsWindowValue,
                sceneController: sceneController,
                viewerSettings: viewerSettings
            )
        } defaultValue: {
            Self.controlsWindowValue
        }
        .defaultSize(width: 460, height: 720)

#if os(visionOS)
        WindowGroup(id: Self.volumeWindowID, for: FlyWorldWindowRoute.self) { _ in
            FlyWorldVolumeView(
                sceneController: sceneController,
                controlsWindowID: Self.controlsWindowID,
                controlsWindowValue: Self.controlsWindowValue,
                viewerSettings: viewerSettings
            )
        } defaultValue: {
            Self.volumeWindowValue
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
        WindowGroup(id: Self.volumeWindowID, for: FlyWorldWindowRoute.self) { _ in
            FlyWorldVolumeView(
                sceneController: sceneController,
                controlsWindowID: Self.controlsWindowID,
                controlsWindowValue: Self.controlsWindowValue,
                viewerSettings: viewerSettings
            )
        } defaultValue: {
            Self.volumeWindowValue
        }
        .defaultSize(width: 1000, height: 760)
#endif
    }
}

enum FlyWorldWindowRoute: String, Codable, Hashable {
    case controls
    case volume
}
