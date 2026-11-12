# Shot forms and package timing

Proposal for owner review.

Keep One generation as the default. Keep the trained-range warning and export short shots at their authored frame count. Use one shot-local 24 fps clock for all three forms. The scene edit list continues to use scene time and can trim the resulting shot.

## Several shots in one generation

Add manifest `shotForm.kind = "innerCuts"` with `cuts` records containing `frame`, `beforeGuidePath` and `afterGuidePath`. Frames are ordered, unique and satisfy `0 < frame < frameCount`. Write the adjacent stills at `frame - 1` and `frame`; share paths with existing guide entries when the frame is already present. Emit a timed `[Shot N] At MM:SS.mmm` line for each cut, with the opening segment numbered 1 at time zero. The viewport and clean pass use a hard camera cut between those samples.

## Long take in beats

Add manifest `shotForm.kind = "beats"` with ordered `beats` containing `startFrame`, `frameCount`, `promptPath`, `startGuidePath` and `endGuidePath`. Beat ranges are half-open and cover the full shot exactly. A boundary guide at the first frame of the next beat is shared by both neighbors. The final boundary uses the last available frame. Each prompt describes its complete beat from its own reference guides, camera, subjects and user-authored dialogue. Store it as a separate UTF-8 file and index it by path.

For the 532-frame check, use ranges `[0,177)`, `[177,355)` and `[355,532)`. The manifest carries 177, 178 and 177 frames, three prompts and four boundary guides. Beat counts are editorial spans. A downstream generation recipe is responsible for any padding or overlap required by its trained frame grid.

Approve the three-form model and these fields before changing `CONTRACTS.md`, the document schema or the package writer.
