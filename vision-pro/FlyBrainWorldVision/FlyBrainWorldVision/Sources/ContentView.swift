import RealityKit
import SwiftUI

struct FlyWorldVolumeView: View {
    let sceneController: FlyWorldSceneController
    @Bindable var viewerSettings: FlyWorldViewerSettings

    var body: some View {
        RealityView { content in
            sceneController.loadIfNeeded()
            sceneController.startPoseUpdates()
            content.add(sceneController.root)
            updateScenePlacement()
        } update: { _ in
            updateScenePlacement()
        } placeholder: {
            ProgressView("Building fly world...")
        }
    }

    private func updateScenePlacement() {
        sceneController.setSceneScale(viewerSettings.sceneScale)
        sceneController.root.position = [0.0, viewerSettings.verticalOffset, viewerSettings.depthOffset]
        sceneController.root.orientation = simd_quatf(angle: viewerSettings.yaw, axis: [0.0, 1.0, 0.0])
    }
}

struct FlyWorldControlWindow: View {
    @Environment(\.openWindow) private var openWindow

    let volumeWindowID: String
    let sceneController: FlyWorldSceneController
    @Bindable var viewerSettings: FlyWorldViewerSettings

    @State private var didAutoOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Fly World Vision")
                    .font(.largeTitle.weight(.semibold))

                Text("Dedicated Vision Pro whole-fly viewer with a separate control window. The volumetric fly stays clean while you adjust size and placement from here.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Open Fly Volume") {
                        openWindow(id: volumeWindowID)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Reset View") {
                        viewerSettings.reset()
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 12) {
                    FlyWorldSlider(title: "Fly Scale", value: $viewerSettings.sceneScale, range: 0.10...0.28, format: "%.2fx")
                    FlyWorldSlider(title: "Floor Offset", value: $viewerSettings.verticalOffset, range: -0.40 ... -0.08, format: "%.2f m")
                    FlyWorldSlider(title: "Depth Offset", value: $viewerSettings.depthOffset, range: -0.16...0.14, format: "%.2f m")
                    FlyWorldSlider(title: "Yaw", value: $viewerSettings.yaw, range: -0.9...0.9, format: "%.2f rad")
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Movement")
                        .font(.headline)

                    Text("If there is no live pose packet in the app Documents directory, the fly auto-walks a demo loop and periodically drinks at the nectar dish.")
                        .foregroundStyle(.secondary)

                    Text("To drive real motion, keep writing `vision_pro_pose_packet.json` or `fly_world_pose_packet.json` into the app Documents directory at roughly 15-30 Hz.")
                        .foregroundStyle(.secondary)
                }

                Divider()

                if let metadata = sceneController.metadata {
                    VStack(alignment: .leading, spacing: 12) {
                        FlyWorldStat(title: "Behavior", value: metadata.behavior?.capitalized ?? "Idle")
                        FlyWorldStat(title: "Packet Age", value: metadata.packetAgeDescription ?? "sample")
                        FlyWorldStat(title: "Graph", value: "\(metadata.formatted(metadata.graphNodeCount)) nodes / \(metadata.formatted(metadata.graphEdgeCount)) edges")
                        FlyWorldStat(title: "Bridge", value: "\(metadata.formatted(metadata.jointCount)) joints, \(metadata.formatted(metadata.brainChannelCount)) brain channels")
                        FlyWorldStat(title: "Pose Source", value: metadata.poseSourceLocation ?? metadata.poseSourceLabel ?? "Bundled sample")
                    }
                } else {
                    Text("Preparing fly world...")
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = sceneController.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(28)
        }
        .task {
            sceneController.loadIfNeeded()
            sceneController.startPoseUpdates()
            guard !didAutoOpen else { return }
            didAutoOpen = true
            openWindow(id: volumeWindowID)
        }
    }
}

private struct FlyWorldSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Float($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
        }
    }
}

private struct FlyWorldStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.semibold))
        }
    }
}
