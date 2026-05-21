import Foundation
import Observation

@MainActor
@Observable
final class FlyWorldViewerSettings {
    private static let packetURLDefaultsKey = "FlyWorldViewerSettings.packetURL"
    private static let stalePoseURLSuffix = ":8765/pose"

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
        self.packetURL = Self.currentPacketURL()
        UserDefaults.standard.set(packetURL, forKey: Self.packetURLDefaultsKey)
    }

    func reset() {
        sceneScale = 0.16
        verticalOffset = -0.28
        depthOffset = 0.0
        yaw = 0.24
        // packetURL intentionally preserved across resets.
    }

    private static func currentPacketURL() -> String {
        let fallback = FlyWorldSceneController.defaultPacketURLString
        guard let saved = UserDefaults.standard.string(forKey: packetURLDefaultsKey) else {
            return fallback
        }
        let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return fallback
        }
        if trimmed.contains(stalePoseURLSuffix), trimmed != fallback {
            return fallback
        }
        return trimmed
    }
}
