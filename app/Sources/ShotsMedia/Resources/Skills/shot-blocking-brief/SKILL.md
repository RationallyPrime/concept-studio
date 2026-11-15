---
name: shot-blocking-brief
description: Reads a written description of one shot, such as a row of a scene sheet's shot table, into a ConceptStudio blocking brief that says who stands where in the frame.
---

# Shot blocking brief

You turn a director's description of one shot into a blocking brief. ConceptStudio then stands a neutral
figure for each character on the location plate, through the plate's own camera. You place nobody yourself:
you only say, in frame terms, what the description says.

You receive the description, and the scene's facts as JSON:

- `characters`: the names of the people and creatures already in the scene.
- `setPieces`: the names of the pieces of the set that are marked on the plate, such as a table or a dais.
- `plates`: the names of the scene's location plates.

Write one brief:

- `shot`: the shot's code or name as the description gives it, such as "TS-01". If it gives none, "New shot".
- `plate`: the plate the description names, exactly as it appears in `plates`. Leave it out if none is named.
- `characters`: one entry for each character the description puts in the frame, in the order it names them.

For each character:

- `name`: the character's name. Use the spelling in `characters` when the description means one of them.
- `asset`: only for a character who is not in `characters`: `person.woman`, `person.man`, `person.child`,
  `person.elderly`, `creature.dragon` or `creature.dragon.spread`.
- `frameX`: where they are across the frame, from 0 at the left edge to 1 at the right edge. "Frame left" is
  about 0.27, the centre 0.5, "frame right" about 0.73. Leave it out when the description doesn't say.
- `show`: how much of them the shot shows: `face` for a close-up, `chestUp` for a medium close-up, `waistUp`
  for a medium shot, `thighsUp` for a medium-full shot, `kneesUp`, or `headToBoots` for a full or wide shot. A
  shot size given once for the whole shot applies to every character. Leave it out when nothing says.
- `relation` and `piece`: when the description stands them `on`, `behind` or `inFrontOf` one of `setPieces`,
  give both, with the piece's name exactly as it appears in `setPieces`. "Behind" means the side away from
  the camera. Give neither when the description names no set piece, or names one that is not in `setPieces`.
- `facing`: `camera`, `away`, `frameLeft`, `frameRight`, or `toward:<name>` for facing another character of
  this brief. Leave it out when the description doesn't say.

Rules:

- Say only what the description says. Leave a field out rather than guess it.
- Never add a character the description doesn't put in the frame, and never describe looks, wardrobe or
  action: the brief is positions only.
- Left and right are the frame's, as the audience sees it.
