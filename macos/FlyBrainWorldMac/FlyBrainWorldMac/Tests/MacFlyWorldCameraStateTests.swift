import XCTest
@testable import FlyBrainWorldMac

final class MacFlyWorldCameraStateTests: XCTestCase {
    func testOrbitWrapsYawAndClampsPitch() {
        var camera = MacFlyWorldCameraState()

        camera.orbit(with: CGSize(width: 800.0, height: 300.0))

        XCTAssertLessThanOrEqual(camera.worldYaw, MacFlyWorldCameraState.yawRange.upperBound)
        XCTAssertGreaterThanOrEqual(camera.worldYaw, MacFlyWorldCameraState.yawRange.lowerBound)
        XCTAssertEqual(camera.worldPitch, MacFlyWorldCameraState.pitchRange.upperBound, accuracy: 0.0001)
    }

    func testPanMovesAndClampsOffsets() {
        var camera = MacFlyWorldCameraState()

        camera.pan(with: CGSize(width: 600.0, height: -600.0))

        XCTAssertEqual(camera.horizontalOffset, MacFlyWorldCameraState.horizontalOffsetRange.upperBound, accuracy: 0.0001)
        XCTAssertEqual(camera.verticalOffset, MacFlyWorldCameraState.verticalOffsetRange.lowerBound, accuracy: 0.0001)
    }

    func testZoomClampsDistance() {
        var camera = MacFlyWorldCameraState()

        camera.zoom(by: -5.0)
        XCTAssertEqual(camera.worldDistance, MacFlyWorldCameraState.worldDistanceRange.lowerBound, accuracy: 0.0001)

        camera.zoom(by: 10.0)
        XCTAssertEqual(camera.worldDistance, MacFlyWorldCameraState.worldDistanceRange.upperBound, accuracy: 0.0001)
    }

    func testResetRestoresDefaultCamera() {
        var camera = MacFlyWorldCameraState()
        camera.pan(with: CGSize(width: 120.0, height: 80.0))
        camera.zoom(by: -0.4)
        camera.orbit(with: CGSize(width: 40.0, height: 30.0))

        camera.reset()

        XCTAssertEqual(camera, MacFlyWorldCameraState())
    }
}
