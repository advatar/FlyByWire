import Observation

@MainActor
@Observable
final class FlyWorldViewerSettings {
    var sceneScale: Float = 0.16
    var verticalOffset: Float = -0.28
    var depthOffset: Float = 0.0
    var yaw: Float = 0.24

    func reset() {
        sceneScale = 0.16
        verticalOffset = -0.28
        depthOffset = 0.0
        yaw = 0.24
    }
}
