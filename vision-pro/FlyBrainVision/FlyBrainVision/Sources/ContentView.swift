import RealityKit
import SwiftUI

struct ContentView: View {
    let sceneController: BrainSceneController
    @Bindable var viewerSettings: BrainViewerSettings

    var body: some View {
        RealityView { content in
            content.add(sceneController.root)
            sceneController.setMode(viewerSettings.mode)
            sceneController.updateTransform(
                uniformScale: viewerSettings.uniformScale,
                depthScale: viewerSettings.depthScale,
                mode: viewerSettings.mode
            )
        } update: { _ in
            sceneController.updateTransform(
                uniformScale: viewerSettings.uniformScale,
                depthScale: viewerSettings.depthScale,
                mode: viewerSettings.mode
            )
        } placeholder: {
            ProgressView(progressLabel)
        }
        .task(id: viewerSettings.mode) {
            await sceneController.loadIfNeeded(for: viewerSettings.mode)
            sceneController.updateTransform(
                uniformScale: viewerSettings.uniformScale,
                depthScale: viewerSettings.depthScale,
                mode: viewerSettings.mode
            )
        }
    }

    private var progressLabel: String {
        switch viewerSettings.mode {
        case .anatomy:
            return "Building fly brain volume..."
        case .graph:
            return "Building connectome graph..."
        case .atlas:
            return "Loading atlas mesh..."
        case .flywire:
            return "Loading FlyWire meshes..."
        case .wholeFly:
            return "Building whole-fly volume..."
        }
    }
}

struct BrainControlWindowView: View {
    @Environment(\.openWindow) private var openWindow

    let volumeWindowID: String
    let sceneController: BrainSceneController
    @Bindable var viewerSettings: BrainViewerSettings

    @State private var didAutoOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Fly Brain Vision")
                    .font(.largeTitle.weight(.semibold))

                Text("Use this side window for view selection and tuning. The volumetric window stays clear so the geometry is not covered by a floating control sheet.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Open 3D Volume") {
                        openWindow(id: volumeWindowID)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Reset Scale") {
                        viewerSettings.resetForCurrentMode()
                    }
                    .buttonStyle(.bordered)
                }

                BrainControlsPanel(
                    mode: $viewerSettings.mode,
                    uniformScale: $viewerSettings.uniformScale,
                    depthScale: $viewerSettings.depthScale,
                    showReference: $viewerSettings.showReference,
                    graphMetadata: sceneController.graphMetadata,
                    atlasMetadata: sceneController.atlasMetadata,
                    flyWireMetadata: sceneController.flyWireMetadata,
                    wholeFlyMetadata: sceneController.wholeFlyMetadata,
                    errorMessage: sceneController.errorMessage
                )

                if viewerSettings.mode == .anatomy && viewerSettings.showReference {
                    BrainReferencePanel()
                }
            }
            .padding(28)
        }
        .task {
            guard !didAutoOpen else { return }
            didAutoOpen = true
            openWindow(id: volumeWindowID)
        }
    }
}

struct BrainControlsPanel: View {
    @Binding var mode: BrainVisualizationMode
    @Binding var uniformScale: Float
    @Binding var depthScale: Float
    @Binding var showReference: Bool
    let graphMetadata: ConnectomeBackbone.Metadata?
    let atlasMetadata: MeshCollectionAsset.Metadata?
    let flyWireMetadata: MeshCollectionAsset.Metadata?
    let wholeFlyMetadata: FlyWorldSceneMetadata?
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("View", selection: $mode) {
                ForEach(BrainVisualizationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if mode == .anatomy {
                Text("Volumetric reconstruction inferred from the 2D neuron slice.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if mode == .graph {
                Text("Real FlyWire v783 connectivity reduced to a readable backbone graph.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if mode == .atlas {
                Text("Public anatomical whole-brain atlas mesh added as a separate scene.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if mode == .flywire {
                Text("Real neuron surface meshes fetched from the public FlyWire v783 segmentation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Procedural whole fly in a flat simulation-style arena, with packet-driven playback when a live pose stream is present.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                LabeledSlider(
                    title: "Scale",
                    value: $uniformScale,
                    range: mode == .wholeFly ? 0.25...1.15 : 0.7...1.45,
                    format: "%.2fx"
                )

                if mode == .anatomy {
                    LabeledSlider(
                        title: "Depth",
                        value: $depthScale,
                        range: 0.45...2.4,
                        format: "%.2fx"
                    )

                    Toggle("Show 2D reference", isOn: $showReference)
                        .toggleStyle(.switch)
                }
            }

            if mode == .graph {
                GraphMetadataCard(metadata: graphMetadata)
            } else if mode == .atlas {
                MeshMetadataCard(metadata: atlasMetadata)
            } else if mode == .flywire {
                MeshMetadataCard(metadata: flyWireMetadata)
            } else if mode == .wholeFly {
                WholeFlyMetadataCard(metadata: wholeFlyMetadata)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct GraphMetadataCard: View {
    let metadata: ConnectomeBackbone.Metadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let metadata {
                HStack(spacing: 10) {
                    GraphStat(
                        title: "Backbone",
                        value: "\(metadata.formatted(metadata.selectedNodeCount)) neurons"
                    )
                    GraphStat(
                        title: "Synapses",
                        value: metadata.formatted(metadata.reducedEdgeCount)
                    )
                }

                HStack(spacing: 10) {
                    GraphStat(
                        title: "Source Nodes",
                        value: metadata.formatted(metadata.sourceNodeCount)
                    )
                    GraphStat(
                        title: "Source Edges",
                        value: metadata.formatted(metadata.sourceEdgeCount)
                    )
                }

                Text(metadata.selectionRule)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Preparing connectome backbone...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MeshMetadataCard: View {
    let metadata: MeshCollectionAsset.Metadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let metadata {
                Text(metadata.title)
                    .font(.subheadline.weight(.semibold))

                Text(metadata.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let rootIDs = metadata.rootIDs, !rootIDs.isEmpty {
                    Text("Root IDs: \(rootIDs.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let sourceURL = metadata.sourceURL {
                    Text(sourceURL)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let source = metadata.source {
                    Text(source)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                Text("Preparing mesh asset...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct WholeFlyMetadataCard: View {
    let metadata: FlyWorldSceneMetadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let metadata {
                HStack(spacing: 10) {
                    GraphStat(
                        title: "Nodes",
                        value: metadata.formatted(metadata.graphNodeCount)
                    )
                    GraphStat(
                        title: "Edges",
                        value: metadata.formatted(metadata.graphEdgeCount)
                    )
                }

                HStack(spacing: 10) {
                    GraphStat(
                        title: "Behavior",
                        value: metadata.behavior?.capitalized ?? "Idle"
                    )
                    GraphStat(
                        title: "Packet",
                        value: metadata.packetAgeDescription ?? "sample"
                    )
                }

                HStack(spacing: 10) {
                    GraphStat(
                        title: "Joints",
                        value: metadata.formatted(metadata.jointCount)
                    )
                    GraphStat(
                        title: "Brain",
                        value: metadata.formatted(metadata.brainChannelCount)
                    )
                    GraphStat(
                        title: "World",
                        value: metadata.formatted(metadata.worldObjectCount)
                    )
                }

                Text(metadata.graphSourceLabel)
                    .font(.subheadline.weight(.semibold))

                if let sourceLocation = metadata.graphSourceLocation {
                    Text(sourceLocation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let poseSource = metadata.poseSourceLabel {
                    Text("\(poseSource): \(metadata.poseSourceLocation ?? "sample_vision_pro_pose_packet.json")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let notes = metadata.graphNotes {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Preparing whole-fly scene...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct GraphStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct LabeledSlider: View {
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

private struct BrainReferencePanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2D Reference")
                .font(.headline)
            Image("BrainReference")
                .resizable()
                .scaledToFit()
                .frame(width: 280)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}

#Preview {
    BrainControlWindowView(
        volumeWindowID: "brain-volume",
        sceneController: BrainSceneController(),
        viewerSettings: BrainViewerSettings()
    )
}
