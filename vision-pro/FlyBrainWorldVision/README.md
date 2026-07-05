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

The macOS viewer starts `simulation/run_live_multi_fly.py` automatically when
its pose URL is the default `http://127.0.0.1:8765/pose`. The visionOS app,
on device or simulator, cannot launch that Mac Python process, so start the
Mac-hosted pose server and paste its printed LAN URL into **LAN Pose Stream**.

To drive motion from the simulator bridge instead, keep updating one of these files:

- `vision_pro_pose_packet.json`
- `fly_world_pose_packet.json`

The packet schema lives in `shared/FlyWorldSharedResources/vision_pro_pose_schema.json`.
It now supports either the original single-fly fields or a multi-fly `agents`
array for injected generation comparisons.
Live/replay packets can also mark an agent with `life_state: "dead"` plus
`death_reason` / `death_time`; the viewer keeps that final simulation pose and
animates the fly falling down instead of hiding or respawning it.

## Bundled fallback flies

The bundled `sample_vision_pro_pose_packet.json` now ships one fly per saved
evolution champion from the sibling `LearningToFly` repository (one entry per
top-level experiment under `LearningToFly/results/`). Cold-launching the app
shows them all walking in a grid, animated by the brain-driven fallback. To
regenerate the bundled packet after retraining, run from `LearningToFly/`:

```bash
python run_static_multi_fly_export.py
```
