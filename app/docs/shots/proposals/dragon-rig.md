# Dragon rig and motion catalog

Proposal for owner review. The plan estimates six to ten days for creature support.

## Rig

Use a scaled root with pelvis, chest, three neck joints, head and jaw, and three tail joints. Each leg has a shoulder or hip, knee, ankle and claw. Each wing has a shoulder, elbow, wrist and tip. Expose a back socket on the chest for a full-transform rider attachment, and a mouth socket for a direction cone. The same pose drives viewport, framing bounds and rendered geometry. Size is an editable shoulder height in metres, with Sgaeyl initially around 7.6 m.

## Motion names

- **Fly in** follows an authored approach path with banking and a wing cycle.
- **Flare and land** transitions to the chosen elevated surface, reaching it at the contact mark.
- **Perch and grip** holds claws against the chosen surface.
- **Lower head to target** aims the neck chain within its reach and shows the resulting head position.
- **Turn head away** aims toward an authored off-target direction.
- **Take off** moves from a perch to an authored exit path.
- **Breathe fire** shows a direction cone from the mouth socket for the marked duration.

Framing presets use evaluated dragon bounds to size the camera distance. The layout and matte use the whole dragon. Add a pose exclusion record with `entityID` and `reason: "noCOCOSkeleton"` to the manifest for the dragon.

Acceptance shot places a standing person below a 9 m wall. The dragon lands on the wall, grips it and brings its head within 3 m of the person. Check surface contact, head distance and the matte against rendered frames. A second check confirms the rider banks with the back socket.
