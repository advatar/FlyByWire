# FlyBrainVision

visionOS app for Apple Vision Pro with five complementary views:

- a stylized volumetric reconstruction inferred from `brain.jpg`
- a real connectome backbone graph derived from the FlyWire v783 connectivity table in `data/2025_Connectivity_783.parquet`
- a public anatomical atlas mesh
- a small bundle of real FlyWire neuron surface meshes
- a procedural whole-fly arena scene with the connectome graph positioned inside the head

The volumetric window is now geometry-only. All view selection and tuning controls live in the companion plain window so they do not sit on top of the 3D content.

## Open in Xcode

```bash
cd vision-pro/FlyBrainVision
xcodegen generate
open FlyBrainVision.xcodeproj
```

## Build From Terminal

```bash
cd vision-pro/FlyBrainVision
xcodegen generate
xcodebuild -project FlyBrainVision.xcodeproj \
  -scheme FlyBrainVision \
  -sdk xrsimulator \
  -destination "generic/platform=visionOS Simulator" \
  CODE_SIGNING_ALLOWED=NO build
```

## Control Window

When the app launches, it opens two windows:

- a plain control window for mode selection, scale, and metadata
- the volumetric brain viewer itself

Use the control window to keep the 3D volume unobstructed.

## Rebuild The Graph Asset

The bundled graph is generated from the full connectome and reduced to a readable backbone.

```bash
cd vision-pro/FlyBrainVision
python3.11 -m venv .venv
.venv/bin/pip install pandas pyarrow numpy scipy networkx
.venv/bin/python tools/build_connectome_backbone.py
```

## Rebuild The Mesh Assets

```bash
cd vision-pro/FlyBrainVision
python3.11 -m venv .venv
.venv/bin/pip install pandas pyarrow numpy scipy networkx cloud-volume trimesh
.venv/bin/python tools/build_atlas_mesh_asset.py
.venv/bin/python tools/build_flywire_mesh_asset.py
```

## Export A Whole-Fly Graph

The whole-fly mode accepts `flybrain_for_vision_pro.json`, `flybrain_p9.json`, `flybrain_focus.json`, or `demo_brain_graph.json` from either the app bundle or the app Documents directory. If none are present, it falls back to the bundled `ConnectivityBackbone.json`.

```bash
cd vision-pro/FlyBrainVision
python3.11 -m venv .venv
.venv/bin/pip install pandas pyarrow numpy scipy
.venv/bin/python tools/export_fly_brain_json.py \
  --repo-root ../.. \
  --max-nodes 420 \
  --max-edges 1200 \
  --output FlyBrainVision/Resources/flybrain_for_vision_pro.json
```

## Pose Packet Playback

The whole-fly view now looks for a pose/world packet in the app Documents directory first, then in the app bundle:

- `vision_pro_pose_packet.json`
- `fly_world_pose_packet.json`
- `sample_vision_pro_pose_packet.json`

The shared schema is in `shared/FlyWorldSharedResources/vision_pro_pose_schema.json`. The bundled sample packet is `shared/FlyWorldSharedResources/sample_vision_pro_pose_packet.json`.

To drive the whole-fly view from the repo's embodied simulation runner:

```bash
cd ../..
python main.py --embodied --packet-path /path/to/app/Documents/vision_pro_pose_packet.json --real-time
```

If the packet contains canonical joint keys such as `LFCoxa`, `LFFemur`, and
`LFTibia`, the viewer plays those leg joints directly. If not, it falls back to
the shared brain-driven gait synthesis.

On macOS that Documents directory is typically `~/Documents`. On visionOS
simulator/device, use the app container Documents directory that the viewer
resolves at runtime.

## Viewer Controls

- `Volume`: stylized 3D anatomy reconstructed from the 2D slice.
- `Graph`: real network backbone using 600 high-degree neurons and 4,712 directed synapses from FlyWire v783.
- `Atlas`: public whole-brain anatomical atlas mesh.
- `Meshes`: real FlyWire neuron surface meshes bundled into the app.
- `Whole Fly`: procedural full-body fly in a simplified simulation-style arena, with packet-driven pose playback when available.
- In `Whole Fly`, the fly is now much smaller inside the volume and sits near the bottom of the scene instead of dominating the full window.
- `Scale`: overall scene size.
- `Depth`: anatomy-only z exaggeration.
- `Show 2D reference`: anatomy-only source image toggle.

## Notes

- The whole-fly body is procedural, not a morphologically exact full-fly mesh.
- The whole-fly graph exporter produces an abstract spectral layout derived from connectivity, not anatomical neuron geometry.
- The app is still a viewer. Physics runs outside the app, but the repo now includes `python main.py --embodied` to generate the live MuJoCo/FlyGym pose packet it consumes.
