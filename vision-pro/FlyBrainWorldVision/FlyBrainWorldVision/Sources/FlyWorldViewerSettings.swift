import Foundation
import Observation

@MainActor
@Observable
final class FlyWorldViewerSettings {
    private static let packetURLDefaultsKey = "FlyWorldViewerSettings.packetURL"

    var sceneScale: Float = 0.16
    var verticalOffset: Float = -0.28
    var depthOffset: Float = 0.0
    var yaw: Float = 0.24
    var packetURL: String {
        didSet {
            UserDefaults.standard.set(packetURL, forKey: Self.packetURLDefaultsKey)
        }
    }

    init() {
        self.packetURL = UserDefaults.standard.string(forKey: Self.packetURLDefaultsKey) ?? ""
    }

    func reset() {
        sceneScale = 0.16
        verticalOffset = -0.28
        depthOffset = 0.0
        yaw = 0.24
        // packetURL intentionally preserved across resets.
    }
}
