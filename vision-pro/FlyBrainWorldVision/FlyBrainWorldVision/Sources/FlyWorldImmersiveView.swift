import ARKit
import RealityKit
import SwiftUI

/// Immersive (mixed-reality) presentation of the fly world. The scene root is
/// reparented onto a `WorldAnchor` aligned with the floor plane that ARKit
/// detects in the user's room, so the flies appear on the actual floor.
struct FlyWorldImmersiveView: View {
    let sceneController: FlyWorldSceneController
    @Bindable var viewerSettings: FlyWorldViewerSettings

    @State private var anchorEntity = AnchorEntity(.plane(
        .horizontal,
        classification: .floor,
        minimumBounds: SIMD2<Float>(0.4, 0.4)
    ))
    @State private var sessionTask: Task<Void, Never>?

    var body: some View {
        RealityView { content in
            sceneController.loadIfNeeded()
            sceneController.startPoseUpdates()

            // The scene root lives inside the floor anchor so RealityKit
            // keeps it pinned to the detected floor plane.
            anchorEntity.addChild(sceneController.root)
            content.add(anchorEntity)

            updateScenePlacement()
        } update: { _ in
            updateScenePlacement()
        }
        .task {
            await runARKitSession()
        }
        .onDisappear {
            sessionTask?.cancel()
            sessionTask = nil
            sceneController.root.removeFromParent()
        }
    }

    private func updateScenePlacement() {
        // In immersive mode the world is the room, so we scale the fly world up
        // a bit and zero the yaw/depth offsets — the user repositions by
        // walking, not by sliders.
        sceneController.setSceneScale(viewerSettings.sceneScale)
        sceneController.root.position = SIMD3<Float>(0.0, 0.0, 0.0)
        sceneController.root.orientation = simd_quatf(angle: viewerSettings.yaw, axis: [0.0, 1.0, 0.0])
    }

    private func runARKitSession() async {
        // AnchorEntity(.plane:) already drives plane detection internally, but
        // we still need an ARKitSession with WorldSensing authorization so the
        // anchor can resolve. This kicks the system into asking the user.
        let session = ARKitSession()
        let provider = PlaneDetectionProvider(alignments: [.horizontal])
        do {
            try await session.run([provider])
        } catch {
            // Authorization denied or unsupported (e.g. simulator) — fall back
            // to a floating scene at the user's feet.
            sessionTask?.cancel()
            return
        }

        // Keep the session alive while the immersive space is on screen.
        for await update in provider.anchorUpdates {
            _ = update // The AnchorEntity wires up reparenting itself.
        }
    }
}
