import Observation

@MainActor
@Observable
final class BrainViewerSettings {
    var mode: BrainVisualizationMode = .anatomy
    var uniformScale: Float = 1.0
    var depthScale: Float = 1.0
    var showReference = true

    func resetForCurrentMode() {
        uniformScale = 1.0
        if mode == .anatomy {
            depthScale = 1.0
        }
    }
}
