# Edit a Shots document from the command line

From the checkout root, apply a JSON array of edits to a ConceptStudio project folder.

```sh
swift run --package-path app ConceptStudio --shots-commands "/path/to/project" ./shots-commands.json
swift run --package-path app shots-export \
  --document "/path/to/project/.conceptstudio/shots.json" --shot shot-4 --out "/path/to/package"
```

The first command writes `.conceptstudio/shots.json`. Open the project folder in the app and choose Shots to continue editing. Each batch uses the native editor's command and validation code. An invalid batch leaves the original document in place. The second command prints the validated package path. Saved prompts are included, and authored dialogue produces a template prompt when none is saved. Intermediate guide stills are written only for explicit guide frames.

The command file uses the Swift `ShotsCommand` Codable format. Each array element is a single object keyed by the command case. Unlabelled arguments are keyed by position, such as `_0`. Use identifiers that are unique in the document. Put new entities and marks after their scene and shot.

```json
[
  {"addScene":{"id":"scene-1","name":"Courtyard","takeID":"take-1","shotID":"shot-4","cameraMarkID":"camera-first"}},
  {"setFrameCount":{"_0":"shot-4","_1":277}},
  {"addEntity":{"_0":"scene-1","_1":{
    "id":"squad-west","assetID":"person.man","name":"West squad",
    "placement":{"position":{"x":0,"y":0,"z":0},"heading":0,"scale":1},
    "formation":{"rows":3,"columns":7,"rowSpacing":0.8,"columnSpacing":0.8}
  }}},
  {"addActorMark":{"_0":"shot-4","_1":"squad-west","_2":{
    "id":"move-west","time":2,"position":{"x":0,"y":0,"z":-3},"gait":"walk"
  }}},
  {"setCameraRig":{"_0":"shot-4","sensor":"super35","rig":"sticks","intensity":0}},
  {"updateCameraMark":{"_0":"shot-4","_1":{
    "id":"camera-first","time":0,"position":{"x":0,"y":7,"z":12},"pan":0,"tilt":-0.5,"focalLength":35
  }}},
  {"setDialogue":{"_0":"shot-4","_1":[{"id":"line-1","startFrame":20,"text":"Hold there."}]}},
  {"setGuideFrames":{"_0":"shot-4","_1":[138]}}
]
```

Omitting a dialogue line's `speakerID` means off-screen. Use an entity ID from the scene to name a visible speaker. Frame numbers are zero-based at 24 fps. Actor and camera mark times are in seconds. Editing a project on disk while it is also open in the app can overwrite the in-memory edit, so close the project while applying a batch.
