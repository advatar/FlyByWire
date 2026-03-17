import RealityKit
import SwiftUI

struct ContentView: View {
    @State private var sceneController = FlyWorldSceneController()
    @State private var camera = MacFlyWorldCameraState()

    var body: some View {
        HSplitView {
            RealityView { content in
                sceneController.loadIfNeeded()
                sceneController.startPoseUpdates()
                content.add(sceneController.root)
                updateScenePlacement()
            } update: { _ in
                updateScenePlacement()
            } placeholder: {
                ProgressView("Building fly world...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay {
                MacFlyWorldMouseControls(camera: $camera)
            }
            .frame(minWidth: 960, minHeight: 760)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.12, blue: 0.16),
                        Color(red: 0.18, green: 0.17, blue: 0.14)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            MacControlPanel(
                metadata: sceneController.metadata,
                errorMessage: sceneController.errorMessage,
                camera: $camera
            )
            .frame(width: 340)
        }
        .frame(minWidth: 1280, minHeight: 860)
    }

    private func updateScenePlacement() {
        sceneController.setSceneScale(camera.sceneScale)
        sceneController.root.position = [camera.horizontalOffset, camera.verticalOffset, -camera.worldDistance]
        sceneController.root.orientation =
            simd_quatf(angle: camera.worldYaw, axis: [0, 1, 0]) *
            simd_quatf(angle: camera.worldPitch, axis: [1, 0, 0])
    }
}

private struct MacControlPanel: View {
    let metadata: FlyWorldSceneMetadata?
    let errorMessage: String?
    @Binding var camera: MacFlyWorldCameraState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Fly World")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                Text("macOS RealityKit viewer for the whole fly, connectome graph, flat arena floor, and nectar dish. If no live Documents pose stream is present, the bundled brain-state channels drive a built-in descending-controller fallback.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Button("Reset View") {
                    camera.reset()
                }
                .buttonStyle(.bordered)

                VStack(alignment: .leading, spacing: 12) {
                    MacSlider(title: "Scene Scale", value: $camera.sceneScale, range: MacFlyWorldCameraState.sceneScaleRange, format: "%.2fx")
                    MacSlider(title: "Yaw", value: $camera.worldYaw, range: MacFlyWorldCameraState.yawRange, format: "%.2f")
                    MacSlider(title: "Pitch", value: $camera.worldPitch, range: MacFlyWorldCameraState.pitchRange, format: "%.2f")
                    MacSlider(title: "Distance", value: $camera.worldDistance, range: MacFlyWorldCameraState.worldDistanceRange, format: "%.2f m")
                    MacSlider(title: "Height", value: $camera.verticalOffset, range: MacFlyWorldCameraState.verticalOffsetRange, format: "%.2f m")
                    MacSlider(title: "Horizontal", value: $camera.horizontalOffset, range: MacFlyWorldCameraState.horizontalOffsetRange, format: "%.2f m")
                }

                Text("Mouse: drag to orbit, Shift-drag or right-drag to pan, and scroll to zoom. Trackpad pinch also zooms.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()

                if let metadata {
                    VStack(alignment: .leading, spacing: 12) {
                        StatsRow(
                            title: "Graph",
                            value: "\(metadata.formatted(metadata.graphNodeCount)) nodes / \(metadata.formatted(metadata.graphEdgeCount)) edges"
                        )
                        StatsRow(
                            title: "Behavior",
                            value: metadata.behavior?.capitalized ?? "Idle"
                        )
                        StatsRow(
                            title: "Packet Age",
                            value: metadata.packetAgeDescription ?? "sample"
                        )
                        StatsRow(
                            title: "Bridge",
                            value: "\(metadata.formatted(metadata.jointCount)) joints, \(metadata.formatted(metadata.brainChannelCount)) brain channels, \(metadata.formatted(metadata.worldObjectCount)) world objects"
                        )
                        StatsRow(
                            title: "Graph Source",
                            value: metadata.graphSourceLocation ?? metadata.graphSourceLabel
                        )

                        if let poseSource = metadata.poseSourceLabel {
                            StatsRow(
                                title: "Pose Source",
                                value: "\(poseSource): \(metadata.poseSourceLocation ?? "sample_vision_pro_pose_packet.json")"
                            )
                        }

                        if let notes = metadata.graphNotes {
                            Text(notes)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Preparing whole-fly scene...")
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct MacSlider: View {
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

private struct StatsRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
        }
    }
}

#Preview {
    ContentView()
}
