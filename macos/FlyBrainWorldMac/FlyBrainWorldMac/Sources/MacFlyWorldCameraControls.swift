import AppKit
import SwiftUI

struct MacFlyWorldCameraState: Equatable {
    static let sceneScaleRange: ClosedRange<Float> = 0.25...1.35
    static let yawRange: ClosedRange<Float> = -Float.pi...Float.pi
    static let pitchRange: ClosedRange<Float> = -0.8...0.7
    static let worldDistanceRange: ClosedRange<Float> = 0.85...3.4
    static let verticalOffsetRange: ClosedRange<Float> = -0.75...0.75
    static let horizontalOffsetRange: ClosedRange<Float> = -0.9...0.9

    var sceneScale: Float = 0.40
    var worldYaw: Float = 0.30
    var worldPitch: Float = -0.16
    var worldDistance: Float = 1.55
    var verticalOffset: Float = -0.18
    var horizontalOffset: Float = 0.0

    mutating func orbit(with delta: CGSize) {
        worldYaw = wrappedAngle(worldYaw + Float(delta.width) * 0.008)
        worldPitch = clamp(worldPitch + Float(delta.height) * 0.006, within: Self.pitchRange)
    }

    mutating func pan(with delta: CGSize) {
        let sensitivity = max(worldDistance * 0.0022, 0.0020)
        horizontalOffset = clamp(horizontalOffset + Float(delta.width) * sensitivity, within: Self.horizontalOffsetRange)
        verticalOffset = clamp(verticalOffset + Float(delta.height) * sensitivity, within: Self.verticalOffsetRange)
    }

    mutating func zoom(by delta: Float) {
        worldDistance = clamp(worldDistance + delta, within: Self.worldDistanceRange)
    }

    mutating func zoom(withMagnification magnification: CGFloat) {
        let scale = clamp(Float(1.0 - magnification), min: 0.35, max: 3.0)
        worldDistance = clamp(worldDistance * scale, within: Self.worldDistanceRange)
    }

    mutating func reset() {
        self = Self()
    }
}

struct MacFlyWorldMouseControls: NSViewRepresentable {
    @Binding var camera: MacFlyWorldCameraState

    func makeCoordinator() -> Coordinator {
        Coordinator(camera: $camera)
    }

    func makeNSView(context: Context) -> MouseInputView {
        let view = MouseInputView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MouseInputView, context: Context) {
        context.coordinator.camera = $camera
        nsView.coordinator = context.coordinator
    }

    final class Coordinator {
        var camera: Binding<MacFlyWorldCameraState>

        init(camera: Binding<MacFlyWorldCameraState>) {
            self.camera = camera
        }

        func orbit(with delta: CGSize) {
            camera.wrappedValue.orbit(with: delta)
        }

        func pan(with delta: CGSize) {
            camera.wrappedValue.pan(with: delta)
        }

        func zoom(by delta: Float) {
            camera.wrappedValue.zoom(by: delta)
        }

        func zoom(withMagnification magnification: CGFloat) {
            camera.wrappedValue.zoom(withMagnification: magnification)
        }
    }

    final class MouseInputView: NSView {
        enum DragMode {
            case orbit
            case pan
        }

        weak var coordinator: Coordinator?
        private var dragMode: DragMode = .orbit

        override var acceptsFirstResponder: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            self
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            dragMode = event.modifierFlags.contains(.shift) ? .pan : .orbit
        }

        override func mouseDragged(with event: NSEvent) {
            handleDrag(event)
        }

        override func rightMouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            dragMode = .pan
        }

        override func rightMouseDragged(with event: NSEvent) {
            coordinator?.pan(with: CGSize(width: event.deltaX, height: event.deltaY))
        }

        override func otherMouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            dragMode = .pan
        }

        override func otherMouseDragged(with event: NSEvent) {
            coordinator?.pan(with: CGSize(width: event.deltaX, height: event.deltaY))
        }

        override func scrollWheel(with event: NSEvent) {
            let sensitivity: Float = event.hasPreciseScrollingDeltas ? 0.006 : 0.10
            coordinator?.zoom(by: Float(-event.scrollingDeltaY) * sensitivity)
        }

        override func magnify(with event: NSEvent) {
            coordinator?.zoom(withMagnification: event.magnification)
        }

        private func handleDrag(_ event: NSEvent) {
            let delta = CGSize(width: event.deltaX, height: event.deltaY)
            switch dragMode {
            case .orbit:
                coordinator?.orbit(with: delta)
            case .pan:
                coordinator?.pan(with: delta)
            }
        }
    }
}

private func clamp(
    _ value: Float,
    within range: ClosedRange<Float>
) -> Float {
    clamp(value, min: range.lowerBound, max: range.upperBound)
}

private func clamp(
    _ value: Float,
    min lowerBound: Float,
    max upperBound: Float
) -> Float {
    Swift.min(Swift.max(value, lowerBound), upperBound)
}

private func wrappedAngle(_ angle: Float) -> Float {
    let twoPi = Float.pi * 2.0
    var wrapped = angle.truncatingRemainder(dividingBy: twoPi)
    if wrapped <= -.pi {
        wrapped += twoPi
    }
    if wrapped > .pi {
        wrapped -= twoPi
    }
    return clamp(wrapped, within: MacFlyWorldCameraState.yawRange)
}
