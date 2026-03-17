# Whole Fly RealityKit Volume for Vision Pro

This starter kit gives you a **native visionOS volumetric window** that renders a **stylized full adult fly** with the **fly-brain** connectome graph positioned inside the head.

## Included

- `WholeFlyRealityKitVolumeApp.swift` — single-file visionOS app source
- `demo_brain_graph.json` — tiny sample graph so the app works immediately
- `export_fly_brain_json.py` — exporter for the `eonsystemspbc/fly-brain` repository

## Quick start

1. In Xcode, create a new **visionOS App** project.
2. Delete the generated starter Swift file.
3. Drag in `WholeFlyRealityKitVolumeApp.swift`.
4. Drag in `demo_brain_graph.json` and make sure **Target Membership** is checked for your app target.
5. Build and run on Apple Vision Pro or the visionOS simulator.

The app opens directly as a **volumetric window**.

## Using the real `fly-brain` data

Run the exporter against a local clone of the repo.

```bash
python export_fly_brain_json.py \
  --repo-root /path/to/fly-brain \
  --max-nodes 500 \
  --max-edges 1500 \
  --output flybrain_for_vision_pro.json
```

Then either:

- add `flybrain_for_vision_pro.json` to your Xcode app target, or
- place `flybrain_for_vision_pro.json` into the app's Documents folder.

The app looks for these names in order:

- `flybrain_for_vision_pro.json`
- `flybrain_p9.json`
- `flybrain_focus.json`
- `demo_brain_graph.json`

If none are found, it falls back to a built-in procedural graph.

## What the app renders

- **Body**: procedural full fly (head, thorax, abdomen, eyes, antennae, wings, halteres, legs)
- **Brain**: connectome graph placed inside the head
- **Style**: translucent exoskeleton so the graph remains visible

## Good knobs to tweak

Inside `WholeFlyRealityKitVolumeApp.swift`:

- `exoskeletonOpacity` — make the body more or less transparent
- `wingOpacity` — tune wing visibility
- `maxNodes` / `maxEdges` in `makeBrainGraphEntity(...)` — performance tuning
- `brainScale` — make the graph larger or smaller inside the head

## Notes

This project gives you a **stylized whole-fly volume** right away.
It is not a morphologically accurate whole-body mesh.
If you later obtain a real full-fly USD/USDZ asset, you can swap the procedural body for that asset and keep the same volumetric-window setup.
