# FlyBrainWorldVision

Dedicated visionOS whole-fly viewer for Apple Vision Pro.

This app only shows the fly-world scene: a small procedural fly, the bundled connectome graph inside the head, a flat arena floor, and a nectar dish. The volumetric window stays free of menus; controls live in a separate plain window.

## Open in Xcode

```bash
cd vision-pro/FlyBrainWorldVision
xcodegen generate
open FlyBrainWorldVision.xcodeproj
```

## Build From Terminal

```bash
cd vision-pro/FlyBrainWorldVision
xcodegen generate
xcodebuild -project FlyBrainWorldVision.xcodeproj \
  -scheme FlyBrainWorldVision \
  -sdk xrsimulator \
  -destination "generic/platform=visionOS Simulator" \
  CODE_SIGNING_ALLOWED=NO build
```

## Movement

If no live packet exists in the app Documents directory, the viewer falls back to a shared descending-controller path that drives locomotion and feeding from the packet's brain-state channels.

To drive motion from the simulator bridge instead, keep updating one of these files:

- `vision_pro_pose_packet.json`
- `fly_world_pose_packet.json`

The packet schema lives in `shared/FlyWorldSharedResources/vision_pro_pose_schema.json`.
