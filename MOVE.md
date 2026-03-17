

Yes — and the clean way to replicate it is to separate **brain**, **body**, **world**, **bridge**, and **viewer**.

Eon’s own technical write-up says their embodied demo used the FlyWire connectome plus a simple neuron model to control a MuJoCo-simulated fly body, and that the body side was **NeuroMechFly** rather than the newer RL whole-body model. In that write-up, they describe NeuroMechFly as an 87-joint articulated fly with simulated vision and olfaction, and say their brain/body sync currently runs every **15 ms**.  [oai_citation:0‡Eon | Upload the Human Mind](https://eon.systems/updates/weve-uploaded-a-fruit-fly)

The most important practical point is that you do **not** need to decode every joint directly from the connectome. Eon explicitly says they currently use a **small set of descending outputs** as a practical interface from the brain model into the body, with hand-chosen mappings for behaviors like turning, forward movement, grooming, and feeding. They specifically mention DNa01/DNa02 for steering, oDN1 for forward velocity, and MN9 for feeding-related output.  [oai_citation:1‡Eon | Upload the Human Mind](https://eon.systems/updates/embodied-brain-emulation)

So the closest public replication path is:

1. Get the **whole fly moving in NeuroMechFly/FlyGym** first.  
2. Replace the high-level turning / behavior signals with outputs from a **brain adapter**.  
3. Stream pose plus optional brain activity into your **RealityKit volume** on Vision Pro.  

That works well because FlyGym already exposes the simulation as a Gym-style sensorimotor loop, with configurable observations and actions, and it is explicitly designed around a brain-level / VNC-level split.  [oai_citation:2‡NeuroMechFly](https://neuromechfly.org/tutorials/gym_basics_and_kinematic_replay.html)

## What to run first

For the brain side, the public `fly-brain` repo exposes `main.py`, a `brain-fly` conda environment, and Brian2 / Brian2CUDA / PyTorch / NEST GPU backends. The repo says it was tested on Linux / Ubuntu 22.04 under WSL2 with an NVIDIA CUDA 12.x GPU, and gives RTX 4070 as an example.  [oai_citation:3‡GitHub](https://github.com/eonsystemspbc/fly-brain)

```bash
git clone https://github.com/eonsystemspbc/fly-brain
cd fly-brain
conda env create -f environment.yml
conda activate brain-fly
python main.py --pytorch --t_run 1 --n_run 1 --no_log_file
```

For the body/world side, FlyGym installs directly with pip, and the docs recommend `flygym[examples]` when you want the tutorial environments such as plume simulation and richer examples.  [oai_citation:4‡GitHub](https://github.com/NeLy-EPFL/flygym)

```bash
python -m venv nmf-env
source nmf-env/bin/activate
pip install "flygym[examples]"
```

## What to use as the 3D world

A big advantage of NeuroMechFly/FlyGym is that the “3D world” part is already public and modular.

The **vision** tutorial shows a custom arena with obstacles plus a moving sphere, and demonstrates a `MovingObjArena` whose object position is updated every simulation step.  [oai_citation:5‡NeuroMechFly](https://neuromechfly.org/tutorials/vision_basics.html)

The **olfaction** tutorial shows an `OdorArena` with attractive and aversive sources, virtual sensors on the antennae and maxillary palps, and a simple hand-tuned controller for odor-guided taxis.  [oai_citation:6‡NeuroMechFly](https://neuromechfly.org/tutorials/olfaction_basics.html)

The **advanced olfaction** tutorial goes further and builds a turbulent odor plume with PhiFlow, then plugs that plume into NeuroMechFly.  [oai_citation:7‡NeuroMechFly](https://neuromechfly.org/tutorials/advanced_olfaction.html)

The **connectome-constrained visual system** tutorial shows a two-fly scenario and integrates a connectome-constrained visual network into NeuroMechFly, which is useful if you want a richer visual pathway than a hand-coded object detector.  [oai_citation:8‡NeuroMechFly](https://neuromechfly.org/tutorials/advanced_vision.html)

That means the shortest believable replica is not “brain first.” It is: **world + moving whole fly + existing FlyGym controller**, then swap in a brain-driven high-level controller. That is also very close to how Eon describes their own stack: slight modifications to existing NeuroMechFly walking controllers, with sparse descending signals acting as control handles.  [oai_citation:9‡Eon | Upload the Human Mind](https://eon.systems/updates/embodied-brain-emulation)

## The bridge you actually need

The bridge can be small.

On the **sensory** side, start with:
- visual object position or looming score,
- left/right odor asymmetry,
- sugar contact on legs or proboscis,
- antennal touch / “virtual dust.”

On the **motor** side, start with:
- forward drive,
- left turn drive,
- right turn drive,
- groom trigger,
- feed trigger.

That is consistent with Eon’s public description: sensory events are mapped into identified sensory pathways, brain activity is updated in a connectome-constrained model, and selected descending outputs are translated into low-dimensional motor commands for the body.  [oai_citation:10‡Eon | Upload the Human Mind](https://eon.systems/updates/embodied-brain-emulation)

In pseudocode, the loop is basically:

```python
obs = world.reset()

while True:
    sensory = encode_from_world(obs)
    brain_state = brain.step(sensory, dt=0.015)
    descending = decode_descending(brain_state)
    action = low_level_controller(descending, obs)
    obs = world.step(action)
    stream_to_vision_pro(obs, brain_state)
```

That is not the full biological motor hierarchy — and Eon says their current system is not either. Their own write-up says those sensory→brain and brain→body mappings are still approximate and, in their current implementation, can be hand-chosen rather than learned.  [oai_citation:11‡Eon | Upload the Human Mind](https://eon.systems/updates/embodied-brain-emulation)

## Where Vision Pro fits

For Vision Pro, the best role for RealityKit is **viewer**, not physics engine. Let MuJoCo / FlyGym remain the source of truth for body motion and sensory state, then stream or export:
- root pose,
- selected joint angles,
- current behavior label,
- optional brain highlights.

That keeps the simulation faithful to the public MuJoCo stack while letting your RealityKit volume focus on rendering, interaction, labeling, and brain overlays. Eon’s public description and NeuroMechFly’s docs both place the actual embodiment and sensorimotor loop in MuJoCo, not in a separate rendering engine.  [oai_citation:12‡Eon | Upload the Human Mind](https://eon.systems/updates/embodied-brain-emulation)

## One caveat worth knowing

The strongest scientific anchor is the **peer-reviewed Nature brain model** by Shiu et al. The public `fly-brain` repo is useful, but I would treat it as a practical engineering starting point rather than assume it is the exact packaged embodied demo. The Nature paper describes the central-brain connectome as having **more than 125,000 neurons and 50 million synaptic connections**, while the public repo headline describes its packaged model as **~138k neurons and ~5M synapses**. That difference suggests some preprocessing, pruning, or a different representation in the public code path, though I cannot verify the exact reason from the sources I found.  [oai_citation:13‡Nature](https://www.nature.com/articles/s41586-024-07763-9)

## Best path from here

The shortest route to a working replica is:

- Use **FlyGym/NeuroMechFly** to get a full fly walking in a custom arena.
- Use a **tiny descending-neuron interface** rather than direct joint decoding.
- Plug in the **`fly-brain`** model as the source of those high-level behavior drives.
- Feed the resulting pose packets into the **RealityKit volume** you already have.

I packaged that architecture into a small bundle here: [guide](sandbox:/mnt/data/fly_world_replication_guide.md?_chatgptios_conversationID=69b8489a-9668-8387-aac0-2da3c7e9829a&_chatgptios_messageID=76bdf0e0-563d-404b-afa4-3f6ac88d1aeb), [brain/body bridge scaffold](sandbox:/mnt/data/brain_body_bridge_scaffold.py?_chatgptios_conversationID=69b8489a-9668-8387-aac0-2da3c7e9829a&_chatgptios_messageID=76bdf0e0-563d-404b-afa4-3f6ac88d1aeb), [Vision Pro pose schema](sandbox:/mnt/data/vision_pro_pose_schema.json?_chatgptios_conversationID=69b8489a-9668-8387-aac0-2da3c7e9829a&_chatgptios_messageID=76bdf0e0-563d-404b-afa4-3f6ac88d1aeb), and [zip bundle](sandbox:/mnt/data/fly_world_replication_bundle.zip?_chatgptios_conversationID=69b8489a-9668-8387-aac0-2da3c7e9829a&_chatgptios_messageID=76bdf0e0-563d-404b-afa4-3f6ac88d1aeb).

Next best step is wiring that pose schema into the RealityKit volume app you already asked for.
