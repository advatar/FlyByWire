# FlyBrainWorldMac

macOS RealityKit companion app for the whole-fly scene.

It uses the same shared graph and pose packet contract as the Vision Pro app, but renders the fly in a regular desktop window with a flat simulation-style arena, nectar dish, and demo walking when no live packet is present.

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

If no external packet exists, the bundled sample packet and arena objects are used, and the fly auto-walks a demo loop.
