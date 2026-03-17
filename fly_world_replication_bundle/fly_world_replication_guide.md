# Replicating the "fly in a 3D world" stack

This guide is for building a **replicable approximation** of the setup described by Eon/Futurism:

1. a connectome-based brain model,
2. a full fly body in a MuJoCo world,
3. sensory inputs from the world into the brain,
4. a small descending-neuron / behavior interface back into the body,
5. a Vision Pro front-end for viewing the result.

## What is public today

The closest public pieces are:

- **Brain:** `eonsystemspbc/fly-brain` (whole-brain leaky integrate-and-fire model built from FlyWire).
- **Peer-reviewed brain model paper:** Shiu et al. / Nature 2024.
- **Body + world:** **NeuroMechFly v2 / FlyGym** (MuJoCo fruit-fly body with vision, olfaction, arenas, cameras, and controllers).
- **Alternative body model:** the DeepMind/Janelia whole-body MuJoCo fly model (walking + flight), useful later if you want to push past walking.

## What is not fully public

The exact embodied demo coupling code is not published as a turnkey repo.
The public Eon write-up says they:

- used **NeuroMechFly**,
- synced brain and body every **15 ms**,
- used **sparse descending-neuron readouts** instead of the full motor hierarchy,
- used **slight modifications to existing NeuroMechFly walking controllers**,
- hand-chose some of the sensory-to-brain and brain-to-body mappings.

So the right goal is not “bitwise reproduce their exact demo”, but “recreate the same architecture with public components.”

## Recommended build order

### Stage 1 — Get the full fly walking in a world

Do this **before** you touch the brain model.

Use FlyGym / NeuroMechFly because it already gives you:

- an anatomically detailed whole-fly body,
- MuJoCo physics,
- cameras,
- arenas,
- odor sources,
- visual objects,
- moving objects,
- tutorials for taxis, turning, and multimodal navigation.

Good starting examples:

- `HybridTurningController` for locomotion,
- `MovingObjArena` / visual taxis for a moving object in the world,
- `OdorArena` / olfaction basics for attractive and aversive sources,
- advanced olfaction for a turbulent odor plume,
- connectome-constrained visual model for richer neural-style vision.

### Stage 2 — Replace the abstract controller with a brain-body bridge

Do **not** try to decode every joint directly from the connectome.

Instead, start with a small set of descending control channels, for example:

- `forward_drive`
- `turn_left_drive`
- `turn_right_drive`
- `groom_drive`
- `feed_drive`
- `escape_drive`

These are the “behavior handles” that sit between the full brain and the low-level body controller.

### Stage 3 — Feed sensory state into the brain model

Build encoders from FlyGym observations into a compact set of sensory drives:

- **vision:** object position / optical flow / looming score
- **olfaction:** left-right antenna asymmetry + total concentration
- **taste:** contact events on legs/proboscis with food objects
- **touch / grooming:** antennal stimulation / “virtual dust”
- **proprioception (optional):** base velocity, heading, or joint summaries

### Stage 4 — Stream pose + brain state to Vision Pro

Keep MuJoCo as the source of truth for physics.
Use RealityKit only as the renderer / UI layer.

For each rendered frame, export:

- root position and orientation,
- selected joint angles,
- optional brain state summary (active neurons, highlighted regions, behavior labels),
- optional world object transforms.

## Minimal architecture

```text
MuJoCo / FlyGym world
        ↓
  sensory encoder
        ↓
 connectome-based brain model
        ↓
 descending-neuron decoder
        ↓
FlyGym / NeuroMechFly controller
        ↓
body motion + new sensory state
        ↓
RealityKit visualizer
```

## The simplest practical replication

If your goal is a convincing demo, this is the shortest path:

1. **Run FlyGym** with a moving-object or odor arena.
2. Use the existing **HybridTurningController** as the low-level gait generator.
3. Replace the high-level 2D turning command with outputs from your brain adapter.
4. Map only a few brain outputs into:
   - left/right turning bias,
   - forward speed,
   - grooming trigger,
   - feeding trigger.
5. Export fly pose to RealityKit.

That gets you a moving whole fly in a world without solving the entire ventral nerve cord.

## Recommended project layout

```text
project/
  brain/
    fly_brain_adapter.py
    sensory_encoder.py
    descending_decoder.py
  body/
    flygym_env.py
    arenas.py
    low_level_controller.py
  runtime/
    main_loop.py
    pose_stream.py
  visionos/
    pose_schema.json
    RealityKit client
```

## Main loop pseudocode

```python
obs = world.reset()
brain = BrainAdapter(...)

while True:
    sensory_drive = encode_sensory(obs)
    brain_state = brain.step(sensory_drive, dt=0.015)
    descending = decode_descending(brain_state)
    action = low_level_controller(descending, obs)
    obs = world.step(action)
    stream_pose_and_state(obs, brain_state)
```

## How to choose the brain-body interface

A very workable first version is:

- **steering** from DNa-like activity
- **forward motion** from oDN-like activity
- **grooming** from antennal-grooming descending activity
- **feeding** from MN9 / feeding-related output

Then map those to FlyGym controls:

- steering → left/right amplitude asymmetry in the turning controller
- forward drive → global gait amplitude / speed scalar
- grooming → switch to a grooming controller or scripted mode
- feeding → proboscis / feeding animation or task state

## Why this works

NeuroMechFly is already designed around a hierarchical CNS/VNC split.
That means it naturally supports the idea that the “brain” sends compact descending commands and lower-level circuitry handles detailed actuation.

## What to keep simple at first

Start with **walking + turning + odor/food seeking**.

Avoid these on day 1:

- full flight,
- learning/plasticity,
- exact motor-neuron reconstruction,
- faithful endocrine/internal state modeling,
- a giant one-shot vision-to-joints policy.

## Suggested milestones

### Milestone A — Body-only demo

- Fly walks in a MuJoCo arena.
- One moving visual object or one food source.
- Camera recording works.

### Milestone B — Brain-in-the-loop demo

- World observations are converted into sensory drives.
- Brain outputs set steering and forward speed.
- Fly approaches an odor source or visually tracked object.

### Milestone C — Multi-behavior demo

- Add grooming trigger from virtual dust / antennal touch.
- Add feeding trigger near a sugar bowl.
- Label current behavior in the HUD.

### Milestone D — Vision Pro demo

- Stream pose to RealityKit.
- Render full fly body + optional brain overlay.
- Allow the user to walk around the fly in a volumetric scene.

## RealityKit advice

Do not re-simulate physics in RealityKit.

Instead:

- simulate in Python / MuJoCo,
- export transforms at a fixed frame rate,
- let RealityKit interpolate poses,
- use the brain overlay only for visualization.

A good first packet format is:

- timestamp
- root transform
- selected joint angles
- behavior label
- optional highlighted neurons / regions

## Exact vs close-enough replication

### Closest to Eon’s described setup

- `fly-brain` for the brain
- NeuroMechFly / FlyGym for the body/world
- sparse descending decoder
- 15 ms brain-body sync
- hand-tuned mappings where needed

### Best engineering path

- FlyGym first
- replace controller gradually
- keep a tiny descending interface
- send state to Vision Pro last

## If you want one concrete first experiment

Build this:

- arena: flat floor + one attractive odor source + one sugar bowl,
- body: FlyGym `HybridTurningController`,
- sensory: odor asymmetry + sugar contact,
- brain readout: `forward`, `left`, `right`, `feed`,
- viewer: RealityKit volume with a whole fly and a small brain heatmap.

That is small enough to finish, but close enough to the public description that it captures the whole idea.
