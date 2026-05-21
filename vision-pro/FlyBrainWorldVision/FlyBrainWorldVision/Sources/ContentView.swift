import RealityKit
import SwiftUI

struct FlyWorldVolumeView: View {
    @Environment(\.openWindow) private var openWindow

    let sceneController: FlyWorldSceneController
    let controlsWindowID: String
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
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .center) {
            Button {
                openWindow(id: controlsWindowID)
            } label: {
                Label("Show Controls", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderedProminent)
            .padding(12)
            .glassBackgroundEffect()
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
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    let volumeWindowID: String
    let controlsWindowID: String
    let immersiveSpaceID: String
    let sceneController: FlyWorldSceneController
    @Bindable var viewerSettings: FlyWorldViewerSettings

    @State private var didAutoOpen = false
    @State private var roomModeActive = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Fly World Vision")
                        .font(.largeTitle.weight(.semibold))
                    Spacer()
                    Button {
                        dismissWindow(id: controlsWindowID)
                    } label: {
                        Label("Hide", systemImage: "eye.slash")
                    }
                    .buttonStyle(.bordered)
                }

                Text("Dedicated Vision Pro whole-fly viewer with a separate control window. Hide this panel any time — bring it back from the Show Controls button under the fly volume.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Open Fly Volume") {
                        openWindow(id: volumeWindowID)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(roomModeActive ? "Exit Room Mode" : "Enter Room Mode", systemImage: roomModeActive ? "rectangle.portrait.and.arrow.right" : "arkit") {
                        Task {
                            if roomModeActive {
                                await dismissImmersiveSpace()
                                roomModeActive = false
                            } else {
                                let result = await openImmersiveSpace(id: immersiveSpaceID)
                                if case .opened = result {
                                    roomModeActive = true
                                    dismissWindow(id: volumeWindowID)
                                }
                            }
                        }
                    }
                    .buttonStyle(.bordered)

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

                    Text("If there is no live LAN stream or Documents pose packet, the viewer animates each fly from its brain-state channels using the bundled fallback.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("LAN Pose Stream")
                        .font(.headline)

                    Text("Using \(FlyWorldSceneController.defaultPacketURLString). Paste another URL only if the Mac's LAN IP changes.")
                        .foregroundStyle(.secondary)
                        .font(.footnote)

                    TextField(FlyWorldSceneController.defaultPacketURLString, text: $viewerSettings.packetURL)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: viewerSettings.packetURL) { _, newValue in
                            sceneController.packetURLString = newValue
                        }

                    HStack(spacing: 8) {
                        Button("Clear") {
                            viewerSettings.packetURL = ""
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewerSettings.packetURL.isEmpty)
                    }
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
            sceneController.packetURLString = viewerSettings.packetURL
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
