# Blocking a scene over its location plate

How to use Shots for a scene once its plates are approved: settle each shot's camera and staging against
the real plate, then hand the key step a picture and a few lines of text, and the video step control that
agrees with both. The requirements are in the brief of 2026-11-13; the formats are in
[CONTRACTS.md](CONTRACTS.md) sections 5.7 to 5.9, 7 and 8.3.

## Once per plate: match its camera

1. Open the project, switch to Shots, and choose the shot.
2. In the inspector under **Location plate**, press **Add plate…** and choose the plate's image. It is
   copied unchanged into the project's `Shots/Plates` folder, and the match screen opens.
3. On the match screen:
   - Drag the two **yellow** lines onto two edges that run the same way in the set and are level with its
     floor, such as the two long edges of a table.
   - Drag the two **blue** lines onto two edges square to those, such as the table's ends or a plinth's
     side. With both pairs the lens and the horizon follow from the lines.
   - Turn on **Find the height from a known height** and put the pink line's foot where something meets
     the floor and its top at that thing's top, then type its height. A table top is about 0.76 m.
   - Check it: the white grid is the floor in one-metre squares, and the green figure is 1.80 m tall. The
     match is right when the grid lies flat on the plate's floor and the figure looks like a person
     wherever you drag it.
   - Anything the lines don't settle can be typed: lens, camera height, tilt, roll and turn.
4. **Save camera match.** Every shot blocked over this plate now starts from this camera, and a later
   correction moves them all.

A second plate of the same set (a reverse, a wider master) gets its own match. Under **Camera position in
the set**:

- give it a position, so both plates look at one set and one blocking serves both;
- for a reverse, press **Face a quarter turn further round** twice, because lines can't tell which way along
  the set the camera looks;
- when the plate shows a different floor from the set's lowest one, type its **Floor level**. A plate taken
  on a dais 0.6 m above the hall gets 0.6. Its lines, its known height, the grid and the figure are then on
  the dais, and stand-ins in the hall below still come out the right size.

This only works when the plates really show one set. Plates made one at a time by an image model often
disagree about sizes and distances; when they do, block each plate in its own scene.

## Once per scene: mark what matters for staging

From the Library add the pieces of the set people stand behind or on: **Long table**, **Dais with steps**,
**Plinth**, **Throne**, **Wall**, **Bench**, **Parapet**, **Arch**, **Column**, **Stairs**, **Block**. Over
a matched plate a new piece starts four metres in front of the camera, square to the set.

- In **Shot camera** or **Side by side** view the piece shows faintly over the plate. Give it a width,
  height and depth in the inspector and move it until it sits on the thing in the plate.
- **Already in the plate** is on for these. They then hide the stand-ins behind them and the plate shows
  through. Turn it off for something the plate lacks, which is then drawn as a grey box.
- People placed over a dais, steps, a plinth or a block stand on top of it.

Dragons are in the Library as **Dragon, wings folded** and **Dragon, wings spread**. A dragon's size is its
standing head height: from the ground to the top of its skull, horns not counted. Scale 1 is 10 m, so the
scale is the height in metres over ten: 1.5 for a dragon that stands 15 m, 1.2 for one of 12 m, 0.76 for
one of 7.6 m.

## Per shot: block it (10 to 15 minutes)

0. A scene's shots share one blocking, so one performance can be covered from several cameras. When this
   shot stages people differently from the others, press **Give this shot its own blocking** under
   **Blocking** first. Everyone stays where they are, and from then on moves here stay in this shot.
1. Choose the shot's plate under **Location plate**. The canvas becomes 576 × 1024 for a 9:16 plate, and
   **Key size** is the plate's own size unless you choose another.
2. Add the characters from the Library and name them in the inspector.
3. Use **Side by side**: drag in the scene view on the left, or click a stand-in in the shot camera on the
   right and drag it along the plate's floor. Turn them with the heading field or the R key.
4. Under **What the shot shows**, say how much of each character the shot is meant to show.
5. Read **Staging in words**. A warning appears there when the framing can't happen on this plate:
   - a set piece hides the part asked for ("the Long table hides Ben below mid-thigh");
   - the frame cuts it, and the camera can't pull back on a plate;
   - a close-up the plate's camera can't reach, with how near the character would have to stand;
   - someone stands inside furniture, or the shot has left its plate's camera.
6. For the motion, add marks and a camera move as before. The first frame stays on the plate.

A first pass can also be written instead of dragged: **Block shots from a description…** in the scene's
menu takes one line per shot, such as

    12A plate C, medium-full. Ada frame left behind the Long table, facing Ben. Ben frame right behind the Long table, facing Ada.

and makes each shot with its characters placed, each shot with its own blocking. Without a language model chosen in Settings it reads the
frame words itself ("frame left", "behind the", "close-up", "facing").

## Export: what each step takes

**Export shot package…** writes into `<shot>/<stamp>-<frames>f-<W>x<H>/` in the scene's export folder. That
is the project's `Shots` folder until you press **Choose export folder…** under Export and pick another,
such as the scene's folder in the production tree. The choice is per scene and is remembered; the line
above the button always says where packages go. Each shot gets its own folder inside the chosen one, so
choose a folder made for them (for example `previs` inside the scene's folder) rather than one whose
`shots` folder means something else. The framing table is saved to the same place.

A package holds:

| For | File | Use |
|---|---|---|
| The key (the image model) | `guides/first-f0000-composition.png` | Image 1 in place of the bare plate: the plate with a coloured stand-in per character, at the key's size, no text |
| The key | `staging.txt` | Paste into the prompt: plate, framing, camera, then where each character is, how much shows and which way they face, and which colour is who |
| People | `guides/first-f0000-composition-labelled.png` | The same picture with name tags, for review |
| The video (H3 Fun ControlNet) | `control/pose.mp4`, `control/layout.mp4` | Control video on the video canvas and frame grid; frame 0 agrees with the composition guide |
| The scene sheet | `staging.json` | The same staging as data |

The stand-ins are flat-coloured mannequins with a nose and a dark band across the eyes, so the guide carries
position, size and facing and nothing of a person's look. A `last-…-composition.png` is written too when the blocking differs at the last frame and
the camera has not moved off the plate.

For the scene sheet, **Compare all shots…** in the scene's menu shows every shot's first frame side by
side and copies or saves the framing table: shot, plate, framing, lens, camera position and who is where.

## Sizes

- **Key size** is the composition guide's size. The plates and keys are 1440 × 2560.
- **Canvas** is the control videos' size. 576 × 1024 is exactly 9:16. 544 × 960 is 0.7% wider than 9:16,
  and Shots warns that control will not line up exactly with a 9:16 key at that size.
- Frame counts stay on H3's grid of 17k + 5.

## From the command line

    swift run -c release shots-export --document <project>/.conceptstudio/shots.json --shot <id> --out <dir>
    swift run -c release shots-export --plate-sample <plate image> --out <dir>
    swift run -c release shots-export --document <shots.json> --block <briefs.json>
    swift run -c release shots-export --document <shots.json> --shot <id> --fit-check <picture.png>

The first reads plates from the project's `Shots/Plates`. The second blocks the built-in throne-room sample
over any image, to see a plate export. The third blocks shots from a file of briefs (CONTRACTS section 5.9)
and saves them into the document for review in the app. The fourth writes what the shot-camera view shows:
the first frame over the plate with the set pieces showing, to check a camera match without opening the app.
