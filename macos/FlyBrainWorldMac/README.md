# FlyBrainWorldMac

macOS RealityKit companion app for the whole-fly scene.

It uses the same shared graph and pose packet contract as the Vision Pro app, but renders the fly in a regular desktop window with a flat simulation-style arena, nectar dish, and a six-leg contact locomotion fallback when no live Documents pose stream is present.

## Open in Xcode

```bash
cd macos/FlyBrainWorldMac
xcodegen generate
open FlyBrainWorldMac.xcodeproj
```

## Build From Terminal

```bash
cd macos/FlyBrainWorldMac
xcodegen generate
xcodebuild -project FlyBrainWorldMac.xcodeproj \
  -scheme FlyBrainWorldMac \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO build
```

## Data Inputs

The app looks for these graph files in the app Documents directory first, then in the app bundle:

- `flybrain_for_vision_pro.json`
- `flybrain_p9.json`
- `flybrain_focus.json`
- `demo_brain_graph.json`

The pose/world stream uses these packet names:

- `vision_pro_pose_packet.json`
- `fly_world_pose_packet.json`
- `sample_vision_pro_pose_packet.json`

If no external packet exists, the bundled sample packet and arena objects are used, and the fly moves from the packet's brain-state channels through the shared fallback locomotion/feeding controller with grounded body support from stance-leg contacts.

To stream a live embodied simulation packet into the app:

```bash
cd ../..
python main.py --embodied --packet-path ~/Documents/vision_pro_pose_packet.json --real-time
```

When the packet includes canonical leg joint keys such as `LFCoxa`, `LFFemur`,
and `LFTibia`, the viewer uses direct leg-joint playback. Legs without direct
angles still fall back to the shared synthesized gait.

The shared packet contract also accepts an optional `agents` array. When present,
the app renders one fly per agent entry, which is how the `LearningToFly`
generation exporter can show several evolved flies at once.

## Viewer Controls

- Drag with the mouse to orbit around the fly.
- Shift-drag or right-drag to pan the scene.
- Scroll the mouse wheel to zoom.
- Use the Reset View button to return to the default framing.
