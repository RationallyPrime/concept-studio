# Shots contracts

This file is the single source of truth for everything that crosses a lane boundary: packages and
targets, file ownership, libraries, conventions, the public Swift API between lanes, file formats and the
integration tests. Inside its own files a lane is free to design as it likes. At these seams it is not.

Read with: [README.md](README.md) (lanes, schedule), [../SHOTS-PLAN.md](../SHOTS-PLAN.md) (why),
[PLATES.md](PLATES.md) (how to block a scene over its plate).

**Blocking over the real location** (the brief of 2026-11-13) added sections 5.7 to 5.9, the plate
commands in section 7, `Shots/Plates` in section 8.1, and the composition guides and staging files in
section 8.3. The document is version 2 and the package format version 2; both readers still read version 1.

## 1. Ground rules

**The declarations here are a specification.**
- Transcribe them into code with the repo's formatting: lines under 120 columns and no aligned trailing
  comments. Keep the names, labels, parameter order and types exactly.
- Code against these declarations, never against another lane's internals. Until the owning lane lands
  a declaration, write against this file.

**Construction.** Every plain public value struct declares a public memberwise initialiser, in property
order. Optionals default to `nil` and arrays and dictionaries to empty; every other parameter, ids
included, is required. Swift's synthesised initialiser is internal, and other modules need to build these
values. `Mat4`, `ShotEvaluator` and `ContentCatalog` have only the initialisers listed.

**Skeletons never crash.**
- Until a function is implemented it throws `ShotsError.notImplemented("<what>")` or returns an empty
  value.
- Never use `fatalError` or `preconditionFailure` as a placeholder: other lanes run your code from day 1.

**Changing a contract.** Open a PR titled `[contract] …` that edits this file and the code together.
- Additive changes merge when CI is green: a new optional field, a new function, or a new enum case no
  consumer must handle.
- Breaking changes need a comment from each consuming lane in the PR. The owner can override.

**Ownership.** Edit only the files your lane owns (section 2). For a change in another lane's file, ask
that lane, or open a contract PR if it is a seam.

**Git.**
- One worktree and one branch per lane: `shots/a-core`, `shots/b-media`, `shots/c-shell` and
  `shots/d-viewport`.
- Rebase on `main` at the start of every session.
- One PR per checkpoint, merged when CI is green, using **rebase or merge commits, not squash**. If a PR is
  squashed anyway, reset the lane branch to `main` before continuing.
- `main` is unprotected. If it moved since your PR's last green run, rebase and wait for green again
  before merging; two stale green PRs can still break it.
- Stage files by name; never `git add -A`. The main checkout holds untracked files that must not be
  published.

**Status.** Each lane keeps `app/docs/shots/status/lane-<a|b|c|d>.md`, holding:
- its checkpoint table;
- how to see today's functionality, as a command or as steps in the app;
- open questions.

The owner reads these once a day. They are public, so they contain no local paths: say how to regenerate
an output, not where yours is. Lane B maintains README.md and the lane documents; this file changes only
through contract PRs.

## 2. Packages, targets and ownership

PrevisCore is a **standalone SwiftPM package** at `app/PrevisCore/` and depends on nothing. It builds and
tests on macOS, and on Linux with a Swift 6 toolchain. The app package uses it as a local dependency.

| Package or target | Kind | Owner | Depends on |
|---|---|---|---|
| `app/PrevisCore` package: library `PrevisCore`, tests `PrevisCoreTests` | standalone package | Lane A | Foundation only |
| `ShotsMedia` (in `app/Package.swift`) | library | Lane B | PrevisCore, ConceptCore |
| `ShotsExportTool` (product `shots-export`) | executable dev tool, not bundled | Lane B | ShotsMedia |
| `ShotsMediaTests` | tests | Lane B | ShotsMedia, PrevisCore |
| `ConceptStudio` (existing) | executable | Lanes C and D | gains PrevisCore and ShotsMedia |
| `ConceptStudioTests` (existing) | tests | Lanes C and D | unchanged |

| Path | Owner |
|---|---|
| `app/PrevisCore/**`, `scripts/blockout/**` | A (W0 creates the package skeleton first) |
| `app/Sources/ShotsMedia/**`, `app/Sources/ShotsExportTool/**`, `app/Tests/ShotsMediaTests/**` | B |
| W0 only: `app/Package.swift`, `app/.swiftlint.yml`, `scripts/render-app-preview.sh`, `mise.toml`; `.github/workflows/ci.yml` (W0, and B1 for `SHOTS_SKIP_RENDER` only) | B |
| `app/Sources/ConceptStudio/Shots/{Model,Workspace,Timeline,Inspector,Library}/**` | C |
| `app/Tests/ConceptStudioTests/Shots/**` except files named `Viewport*.swift` | C |
| Edits to existing files: `StudioSession*.swift`, `StudioRootView.swift`, `ConceptStudioApp.swift`, `StudioHelpView.swift`, `DemoProject.swift`, `AppLifetime.swift` (the Shots save seam at quit and window close), `Resources/Glossary/conceptstudio-operations.json`, `PreviewRenderTests.swift` | C |
| `app/Sources/ConceptStudio/Shots/Viewport/**`, `app/Tests/ConceptStudioTests/Shots/Viewport*.swift` | D |
| `app/docs/shots/status/lane-x.md` | each lane its own |

**W0** (Lane B, first, about an hour) makes every shared build change, so later lanes never touch them:

`app/PrevisCore/Package.swift` (the tools-version comment must be its first line):

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrevisCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "PrevisCore", targets: ["PrevisCore"])],
    targets: [
        .target(name: "PrevisCore", resources: [.copy("Resources")], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "PrevisCoreTests", dependencies: ["PrevisCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
```

```swift
// app/Package.swift additions
dependencies: [/* existing */, .package(path: "PrevisCore")],
products: [/* existing */, .executable(name: "shots-export", targets: ["ShotsExportTool"])],
.target(
    name: "ShotsMedia",
    dependencies: [.product(name: "PrevisCore", package: "PrevisCore"), "ConceptCore"],
    resources: [.copy("Resources")],
    swiftSettings: [.swiftLanguageMode(.v6)]
),
.executableTarget(name: "ShotsExportTool", dependencies: ["ShotsMedia"], swiftSettings: [.swiftLanguageMode(.v6)]),
.testTarget(
    name: "ShotsMediaTests",
    dependencies: ["ShotsMedia", .product(name: "PrevisCore", package: "PrevisCore")],
    swiftSettings: [.swiftLanguageMode(.v6)]
),
// ConceptStudio target: add .product(name: "PrevisCore", package: "PrevisCore") and "ShotsMedia".
```

W0 also does the following:
- Commits a file in every new source folder and **every resources folder**, because git drops empty
  folders and SwiftPM refuses a missing resources folder. That covers
  `PrevisCore/Sources/PrevisCore/Resources/LICENSE` and `NOTICE`, and
  `ShotsMedia/Resources/README.md`.
- Adds a CI step right after the app's test step:
  `../.github/scripts/swift-test-watchdog.sh --package-path PrevisCore`.
- Adds `PrevisCore/Sources` and `PrevisCore/Tests` to `included` in `app/.swiftlint.yml`, and to the
  swiftformat paths in CI. List those two folders, never `PrevisCore` itself: swiftlint would then lint
  SwiftPM's generated files under `PrevisCore/.build` and fail.
- Teaches `scripts/render-app-preview.sh` to copy `PrevisCore/Package.swift`, `PrevisCore/Sources` and
  `PrevisCore/Tests` into its snapshot, never a local `.build`.
- Pins `bun = "1.3.14"` in `mise.toml`.

`scripts/build-app.sh` already copies every `*.bundle` into the app, so the PrevisCore and ShotsMedia
resource bundles ship. They carry Blockout's LICENSE and NOTICE.

## 3. Libraries and tools

There are no new SwiftPM dependencies. Shots uses only these:

| Allowed | For |
|---|---|
| Swift standard library, Foundation, Observation, Synchronization, `os.Logger` (subsystem `is.conceptstudio.app`, category `shots`) | all |
| SwiftUI; AppKit only where SwiftUI cannot do it (event modifiers, scroll wheel) | C, D |
| RealityKit | B (rendering), D (viewport) |
| Metal (resources RealityKit needs; no `.metal` shader files), CoreVideo, CoreMedia, AVFoundation, CoreGraphics, CoreText (name tags), ImageIO, UniformTypeIdentifiers | B |
| ConceptCore: model clients, `StructuredStage`, Agent Skills loader, `AtomicFile`, `JSONValue` | B (prompt), C (persistence) |
| bun (pinned in `mise.toml`) | `scripts/blockout/` only; never at app runtime |

PrevisCore imports Foundation and nothing else, so it stays portable. Tests use Swift Testing
(`import Testing`).

## 4. Conventions

- **Units.** Metres, seconds and radians in data and API. The one exception is focal length, in
  millimetres. Degrees appear only in UI text.
- **Axes.** Y is up, right-handed. Entity heading 0 faces −Z; positive heading turns counter-clockwise seen
  from above, toward −X. Forward for heading θ is (−sin θ, 0, −cos θ).
- **Camera.** R = Ry(pan) · Rx(tilt) · Rz(roll). The camera looks down its local −Z, and positive tilt
  looks up.
- **Left and right.** Rig `L`/`R` joints and the `left`/`right` keypoints are the character's own sides. A
  character facing −Z has its right side toward +X.
- **Joint overrides.** Stored values are radians added to the gait pose. For a person facing −Z, a positive value:
  - `shoulderLX`/`shoulderRX` swings the arm back; a negative one raises it forward and up
    (−2.3 ≈ straight up and forward);
  - `shoulderLZ`/`shoulderRZ` raises the arm out to its own side;
  - `elbowL`/`elbowR` bends the forearm toward the upper arm;
  - `hipLX`/`hipRX` swings the leg back; a negative one swings it forward (−1.6 ≈ a high front kick);
  - `hipLZ`/`hipRZ` swings the leg out to its own side;
  - `kneeL`/`kneeR` bends the knee;
  - `torsoX` leans forward, `torsoY` turns the chest toward the character's left (counterclockwise seen
    from above), `torsoZ` leans right;
  - `headX` nods down, `headY` turns the face toward the character's left, `headZ` tilts right.

  These follow Blockout's sign header (`src/engine/motions.ts` lines 13–33 at `3f2d056`) and its motion data,
  which govern where its renderer disagrees (LANE-A-CORE.md, person rig). The header gives no sign for `headX`
  or `headY`: Blockout's `nod-yes` uses only positive `headX`, and A3's rig turns `headY` the same way as
  `torsoY`. The person rig's sign mapping is the one place they are applied. Blockout's keyframes that bend
  both knees write the thighs' forward swing with a positive `hipX`, against this table; the bundled catalog
  changes those signs (PrevisCore `MotionCorrections`, owner ruling 2026-11-09), so every catalog motion follows
  the table. A document imported from Blockout keeps the values it carries.
- **Time.**
  - H3 runs at 24 fps. A shot stores a frame count on the grid 17k+5 (5, 22, 39, …, 124, …, 362).
  - Frame *i* samples t = i/24, and the last frame samples t = (N−1)/24, the shot's `duration`.
  - Marks carry seconds; the UI snaps them to frames.
- **Pixels.** Origin at the top left, y down.
  - A **shot canvas** is width × height in multiples of 32, within 64…2048. The default is 640 × 1152.
  - A **key size** is the size of the still an image model makes from a composition guide: any width and
    height within 64…4096. It has the plate's shape; 1440 × 2560 is usual.
  - Camera maths takes any positive **pixel size** (`PixelSize`), because the viewport isn't a canvas.
- **Projection.** A pinhole with vertical field of view `verticalFOV` and aspect = width/height.
  - Normalised coordinates: x = (f/aspect)·x_c/(−z_c) and y = f·y_c/(−z_c), with f = 1/tan(vfov/2).
  - Pixels: px = (x+1)/2·W and py = (1−y)/2·H.
  - Near 0.05, far 500.
  - RealityKit's perspective camera with a vertical field of view must agree within 0.5 px; B1 verifies
    it.
- **IDs.** Strings from `PrevisIDs.make(prefix)`: `<prefix>_<12 lowercase hex>`, random. Imported Blockout
  ids are kept when asked.
- **Determinism.** Evaluation and validation are deterministic: the same input gives the same output, bit
  for bit, on one machine. Generators that create marks make new random ids.
- **Colour.** `RGB` holds 8-bit sRGB values. Each component is stored as n/255; JSON is `"#rrggbb"`.
- **JSON.**
  - Keys are the Swift property names.
  - Written with `[.prettyPrinted, .sortedKeys]`.
  - Readers ignore unknown keys and default absent fields.
  - A version newer than the reader supports is an error: refuse it, never overwrite it.
- **Errors.** Plain sentences that name the thing and the fix, shown through the app's single failure
  path: setting `StudioSession.errorMessage` opens the window alert. Nothing fails silently.

## 5. PrevisCore (Lane A)

Pure, `Sendable` value types. Bodies are omitted; the comments give the semantics. Every public struct
also has the public memberwise initialiser from section 1.

### 5.1 Values

```swift
public struct Vec3: Codable, Hashable, Sendable {
    public var x: Double, y: Double, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double)
    public static let zero: Vec3
}
public struct Point2: Codable, Hashable, Sendable { public var x: Double, y: Double }
public struct PixelSize: Codable, Hashable, Sendable {
    public var width: Int, height: Int      // any positive size
    public var aspect: Double { get }
}
public struct Quat: Codable, Hashable, Sendable {
    public var x: Double, y: Double, z: Double, w: Double
    public static let identity: Quat
    public static func yaw(_ heading: Double) -> Quat
}
public struct Mat4: Hashable, Sendable {
    public var m: [Double]                  // 16 values, column-major; m[12...14] = translation
    public static let identity: Mat4
    public static func * (a: Mat4, b: Mat4) -> Mat4
    public func transform(_ point: Vec3) -> Vec3
    public var inverse: Mat4 { get }
}
public struct Box3: Hashable, Sendable { public var min: Vec3, max: Vec3 }
public struct RGB: Codable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double   // 0...1, quantised to n/255
    public init(r: Double, g: Double, b: Double)
    public init(hex: String)
}
public struct ShotCanvas: Codable, Hashable, Sendable {
    public var width: Int, height: Int
    public var aspect: Double { get }
    public var pixelSize: PixelSize { get }
    public var isValid: Bool { get }        // multiples of 32 within 64...2048
    public var isValidStill: Bool { get }   // a key size: 64...4096 on each side
    public static let portrait: ShotCanvas  // 640 × 1152, the default
    public static let portrait9x16: ShotCanvas  // 576 × 1024, the 9:16 video canvas
    public static let presets: [ShotCanvas] // 640×1152, 768×1344, 1152×640, 1344×768, 768×768,
                                            // 576×1024, 864×1536, 544×960
    public static let keyPresets: [ShotCanvas]  // 1440×2560, 1080×1920, 864×1536, 576×1024
}
public enum FrameGrid {
    public static let fps: Int                          // 24
    public static let defaultFrameCount: Int            // 124
    public static let trainedRange: ClosedRange<Int>    // 124...362; outside is allowed, with a warning
    public static func isValid(_ frameCount: Int) -> Bool
    public static func snap(_ frameCount: Int) -> Int   // nearest valid count, ties up, at least 5
    public static func snapUp(_ frameCount: Int) -> Int // smallest valid count >= frameCount
    public static func time(ofFrame index: Int) -> Double
    public static func frame(atTime time: Double) -> Int
}
public enum PrevisIDs { public static func make(_ prefix: String) -> String }
```

### 5.2 The document

```swift
public typealias SceneID = String
public typealias ShotID = String
public typealias EntityID = String
public typealias MarkID = String
public typealias TakeID = String

public struct ShotsDocument: Codable, Sendable, Equatable {
    public static let currentVersion: Int   // 2; version 1 files read unchanged
    public var version: Int
    public var scenes: [PrevisScene]
}

public struct PrevisScene: Codable, Sendable, Equatable, Identifiable {
    public var id: SceneID
    public var name: String
    public var revision: Int                // bumped by the store on every edit except setPrompt
    public var lighting: LightingPreset
    public var entities: [PrevisEntity]
    public var blocking: [BlockingTake]     // one take shared by the scene's shots, until a shot gets its own (5.9)
    public var shots: [Shot]
    public var plates: [LocationPlate]      // section 5.7; a shot names the one it is blocked over
    public static func make(id: SceneID, name: String, takeID: TakeID, shotID: ShotID,
                            cameraMarkID: MarkID) -> PrevisScene
}
public enum LightingPreset: String, Codable, Sendable, CaseIterable {
    case day, goldenHour, night, interiorWarm, interiorCool
}

public struct PrevisEntity: Codable, Sendable, Equatable, Identifiable {
    public var id: EntityID
    public var assetID: String              // fixed once placed
    public var name: String
    public var label: EntityLabel?
    public var placement: Placement         // pose before the first mark, and always if there are none
    public var attachment: EntityAttachment? // rides the parent until its own first mark
    public var setPiece: SetPiece?          // section 5.7; a sized piece of the set, asset `set.<kind>`
}
public struct Placement: Codable, Sendable, Equatable {
    public var position: Vec3
    public var heading: Double
    public var scale: Double                // uniform; also scales gait stride
}
public struct EntityLabel: Codable, Sendable, Equatable { public var text: String; public var color: RGB }
public struct EntityAttachment: Codable, Sendable, Equatable {
    public var parentID: EntityID
    public var offset: Vec3                 // in the parent's frame
    public var rotation: Quat               // relative to the parent: a full transform, not yaw only
}

public struct BlockingTake: Codable, Sendable, Equatable, Identifiable {
    public var id: TakeID
    public var name: String
    public var tracks: [Track]
}
public struct Track: Codable, Sendable, Equatable { public var entityID: EntityID; public var marks: [ActorMark] }
public struct ActorMark: Codable, Sendable, Equatable, Identifiable {
    public var id: MarkID
    public var time: Double                 // seconds from the first frame
    public var hold: Double                 // seconds to stay before leaving for the next mark
    public var easeIn: Double, easeOut: Double
    public var position: Vec3
    public var via: [Vec3]                  // waypoints between the previous mark and this one
    public var gait: Gait
    public var arriveHeading: Double?       // facing at this mark; nil = along travel
    public var joints: [Joint: Double]      // pose overrides, radians; JSON object keyed by joint name
    public var boardID: EntityID?           // from this mark on, ride that entity
}
public enum Gait: String, Codable, Sendable, CaseIterable { case stand, walk, jog, run, sit, lie, crouch, gesture, fall }
public enum Joint: String, Codable, CodingKeyRepresentable, Sendable, CaseIterable {
    case shoulderLX, shoulderLZ, shoulderRX, shoulderRZ, elbowL, elbowR
    case hipLX, hipLZ, hipRX, hipRZ, kneeL, kneeR
    case torsoX, torsoY, torsoZ, headX, headY, headZ
}

public struct Shot: Codable, Sendable, Equatable, Identifiable {
    public var id: ShotID
    public var name: String
    public var frameCount: Int              // on the grid
    public var canvas: ShotCanvas
    public var blockingTakeID: TakeID
    public var camera: ShotCamera
    public var guideFrames: [Int]           // extra middle guides: sorted, unique, within 1...frameCount-2
    public var notes: ShotNotes
    public var prompt: ShotPrompt?
    public var results: [ShotResult]        // reserved for later destinations; empty in v1
    public var plateID: PlateID?            // the plate the shot is blocked over; nil = the grey stage
    public var keyCanvas: ShotCanvas?       // the key's size; nil = the plate's own, or the canvas
    public var asks: [FramingAsk]           // section 5.8; how much of each character the shot shows
    public var duration: Double { get }     // Double(frameCount - 1) / 24
    public mutating func block(over plate: LocationPlate)   // section 5.9
    public static func make(id: ShotID, name: String, takeID: TakeID, cameraMarkID: MarkID) -> Shot
}
public struct ShotCamera: Codable, Sendable, Equatable {
    public var sensor: Sensor
    public var rig: Rig
    public var rigIntensity: Double         // 0...1
    public var seed: Double                 // rig-noise seed; Double for Blockout parity
    public var mountID: EntityID?           // car mount: marks are relative to this entity
    public var trackIDs: [EntityID]         // aim lock: none, one entity, or the midpoint of several
    public var marks: [CameraMark]
}
public enum Sensor: String, Codable, Sendable, CaseIterable { case super16, super35, fullFrame, imax65 }
public enum Rig: String, Codable, Sendable, CaseIterable {
    case sticks, dolly, steadicam, handheld, crane, drone, carMount
}
public struct CameraMark: Codable, Sendable, Equatable, Identifiable {
    public var id: MarkID
    public var time: Double, hold: Double, easeIn: Double, easeOut: Double
    public var position: Vec3
    public var via: [Vec3]
    public var pan: Double, tilt: Double, roll: Double
    public var focalLength: Double          // millimetres
    public var focusDistance: Double?       // metres; nil = deep focus
}
public struct ShotNotes: Codable, Sendable, Equatable {   // v1 choice; may change after Phase 0
    public var description: String          // setting and action in the user's words
    public var characters: [CharacterNote]
    public var sound: String
    public var music: String
}
public struct CharacterNote: Codable, Sendable, Equatable { public var entityID: EntityID; public var appearance: String }
public struct ShotPrompt: Codable, Sendable, Equatable {
    public var sections: [PromptSection]    // in prompt order
    public var text: String                 // the full prompt, exactly as pasted into the graph
    public var sceneRevision: Int           // revision it was written from; behind the scene = stale
    public var writtenBy: String            // "template" or the model name
}
public struct PromptSection: Codable, Sendable, Equatable { public var key: String; public var text: String }
public struct ShotResult: Codable, Sendable, Equatable, Identifiable {
    public var id: String, kind: String, path: String
    public var sceneRevision: Int
}
```

Factory defaults (`make`):
- A new scene has one take, "Master", and one shot, "1A".
- A new shot has 124 frames, a 640 × 1152 canvas, a super35 sensor, the sticks rig at intensity 0, seed 1,
  and no guide frames.
- Its single camera mark is at time 0, position (0, 1.6, 6), pan 0, tilt 0, with a 35 mm lens.

### 5.3 Content

```swift
public struct ContentCatalog: Sendable {
    public static func bundled() throws -> ContentCatalog   // Resources/*.v1.json; errors name the missing file or id
    public let motions: [MotionPreset]
    public let assets: [AssetSpec]                          // environment kits are not loaded
    public let cameraMoves: [CatalogItem]
    public let actionPaths: [CatalogItem]
    public let starter: StarterSet
    public func motion(_ id: String) -> MotionPreset?
    public func asset(_ id: String) -> AssetSpec?
}
public struct StarterSet: Codable, Sendable, Equatable {
    public var assets: [String], motions: [String], cameraMoves: [String], actionPaths: [String]
}
public struct CatalogItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String, name: String, category: String, description: String
    public var track: Bool?                 // camera moves: aim-locks the subject
}
public struct MotionPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: String, name: String, category: String
    public var duration: Double
    public var loop: Bool
    public var keyframes: [MotionKeyframe]
    public var upperBodyOnly: Bool { get }  // touches no hip or knee joint
}
public struct MotionKeyframe: Codable, Sendable, Equatable {
    public var t: Double
    public var joints: [Joint: Double]
    public var move: RootMove?
}
public struct RootMove: Codable, Sendable, Equatable {
    public var forward: Double              // 0 when absent in the data
    public var up: Double                   // 0 when absent in the data
}
public struct AssetSpec: Codable, Sendable, Equatable, Identifiable {
    public var id: String, name: String, category: String
    public var height: Double               // metres at scale 1
    public var footprint: Double            // metres, largest horizontal extent
    public var speedScale: Double
    public var motion: String               // biped, quadruped, wheeled, rail, flying, static
    public var promptNoun: String
    public var parts: [PartSpec]?           // from parts.v1.json; nil = generic box
    public var rig: AssetRig { get }        // person for biped, quadruped, bird for animal.bird, else none
}
public enum AssetRig: String, Sendable { case none, person, quadruped, bird }
public struct PartSpec: Codable, Sendable, Equatable {
    public var id: String
    public var shape: PartShape
    public var position: Vec3               // asset frame, origin on the ground
    public var rotation: Vec3               // Euler XYZ, radians
    public var color: RGB
}
public enum PartShape: Codable, Hashable, Sendable {   // centred on the local origin, axis +Y
    case box(size: Vec3)
    case cylinder(radius: Double, height: Double)
    case sphere(radius: Double)
    case capsule(radius: Double, length: Double)       // straight part; total height length + 2·radius
    case cone(radius: Double, height: Double)
    case wedge(size: Vec3)                             // ramp rising toward −Z
}
```

### 5.4 Evaluation

```swift
public struct ShotEvaluator: Sendable {
    public init(scene: PrevisScene, shotID: ShotID, catalog: ContentCatalog) throws   // ShotsError.invalid
    public var frameCount: Int { get }
    public func frame(_ index: Int) -> SceneFrame      // clamped to 0..<frameCount
    public func frame(at time: Double) -> SceneFrame   // clamped to 0...duration
    public func warnings() -> [ShotsProblem]           // speed, 180° line, trained range, marks past the end,
                                                       // and the staging warnings of section 5.8
    public func staging(atFrame index: Int = 0) -> Staging   // section 5.8
    public func paths() -> [MotionPath]                // for ribbons and spike marks
}
public struct SceneFrame: Sendable, Equatable {
    public var index: Int?                  // set when evaluated on the grid
    public var time: Double
    public var canvas: ShotCanvas
    public var camera: CameraFrame          // field of view for the canvas aspect
    public var entities: [EntityFrame]      // document order
    public var plate: LocationPlate?        // the plate the shot is blocked over
}
public struct CameraFrame: Sendable, Equatable {
    public var position: Vec3
    public var pan: Double, tilt: Double, roll: Double
    public var focalLength: Double
    public var focusDistance: Double?
    public var verticalFOV: Double          // radians
    public var orientation: Quat { get }
    public func viewMatrix() -> Mat4        // world → camera
    public func projection(aspect: Double) -> Mat4
    public func project(_ point: Vec3, size: PixelSize) -> Point2?   // nil behind the camera
    public func ray(through pixel: Point2, size: PixelSize) -> (origin: Vec3, direction: Vec3)
    public static func make(position: Vec3, pan: Double, tilt: Double, roll: Double,
                            focalLength: Double, sensor: Sensor, aspect: Double) -> CameraFrame
}
public struct EntityFrame: Sendable, Equatable {
    public var id: EntityID
    public var assetID: String
    public var name: String
    public var label: EntityLabel?
    public var isActor: Bool                // rigged asset, labelled, or a creature: gets a matte and a layout box
    public var position: Vec3
    public var heading: Double
    public var gait: Gait
    public var speed: Double
    public var distanceTravelled: Double
    public var joints: [Joint: Double]      // evaluated pose overrides, before the gait pose
    public var parts: [PosedPart]
    public var keypoints: [Keypoint]        // COCO-18 world positions; empty unless rig == .person
    public var bounds: Box3
    public var setPiece: SetPiece?          // set for a piece of the set; never an actor
    public var isInPlate: Bool { get }      // a set piece the plate already shows
}
public struct PosedPart: Sendable, Equatable {
    public var id: String                   // stable within the entity across frames
    public var shape: PartShape
    public var transform: Mat4              // part → world, including the entity scale
    public var color: RGB
}
public struct Keypoint: Sendable, Equatable { public var name: KeypointName; public var position: Vec3 }
public enum KeypointName: Int, Sendable, CaseIterable {   // OpenPose COCO-18 order
    case nose = 0, neck, rightShoulder, rightElbow, rightWrist, leftShoulder, leftElbow, leftWrist
    case rightHip, rightKnee, rightAnkle, leftHip, leftKnee, leftAnkle, rightEye, leftEye, rightEar, leftEar
}
public struct MotionPath: Sendable, Equatable {
    public enum Subject: Sendable, Equatable { case entity(EntityID), camera }
    public var subject: Subject
    public var points: [Vec3]
    public var marks: [PathMark]
}
public struct PathMark: Sendable, Equatable { public var id: MarkID; public var time: Double; public var position: Vec3 }
```

### 5.5 Generators and helpers

```swift
public enum CameraMoves {     // several subjects act as one virtual subject at their midpoint
    public static func marks(_ moveID: String, scene: PrevisScene, shotID: ShotID, subjects: [EntityID],
                             catalog: ContentCatalog) throws -> (marks: [CameraMark], trackIDs: [EntityID])
}
public enum ActionPaths {     // speed nil keeps Blockout's timing; otherwise metres per second
    public static func marks(_ pathID: String, entity: PrevisEntity, startTime: Double, duration: Double,
                             speed: Double?, catalog: ContentCatalog) throws -> [ActorMark]
}
public enum Motions {
    public static func apply(_ motionID: String, to entity: PrevisEntity, track: Track?, at time: Double,
                             catalog: ContentCatalog) throws -> Track
    public static func overlay(_ motionID: String, onto track: Track,
                               catalog: ContentCatalog) throws -> Track   // walk-and-talk
}
public enum Framing {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case wide, full, medium, closeUp, twoShot, overShoulder, reverse, top, low, dutch
    }
    public static func cameraMark(_ kind: Kind, scene: PrevisScene, shotID: ShotID, subjects: [EntityID],
                                  atFrame: Int, catalog: ContentCatalog) throws -> CameraMark
}
public enum Attachments {
    public static func attachment(child: EntityID, parent: EntityID, scene: PrevisScene, shotID: ShotID,
                                  atFrame: Int, catalog: ContentCatalog) throws -> EntityAttachment
    public static func placementWhenDetached(child: EntityID, scene: PrevisScene, shotID: ShotID,
                                             atFrame: Int, catalog: ContentCatalog) throws -> Placement
}
```

### 5.6 Validation, import, samples

```swift
public struct ShotsProblem: Sendable, Hashable {
    public enum Severity: Sendable, Hashable { case error, warning }
    public var severity: Severity
    public var message: String              // shown to the user as is
    public var sceneID: SceneID?, shotID: ShotID?, entityID: EntityID?, markID: MarkID?
}
public enum ShotsError: Error, LocalizedError, Sendable {
    case invalid([ShotsProblem])
    case unknownContent(String)             // an asset, motion, move or path id
    case unsupportedVersion(Int)
    case importFailed(String)
    case notImplemented(String)             // skeleton placeholder
}
public enum ShotsValidation {
    public static func problems(in document: ShotsDocument, catalog: ContentCatalog) -> [ShotsProblem]
}
public enum BlockoutImport {                // notes: what was dropped or changed, in plain sentences
    public static func document(fromProjectJSON data: Data, catalog: ContentCatalog,
                                keepIDs: Bool = false) throws -> (document: ShotsDocument, notes: [String])
}
public enum ShotsSamples {
    public static func twoPersonWalk(small: Bool = false) -> ShotsDocument
    // fixed ids. Full: 124 frames, 640×1152, guideFrames [61]. Small: 22 frames, 320×576, guideFrames [11].
    public static func blockoutProjectJSON() -> Data      // small Blockout-format project for import tests
}
public enum PrevisCoreAttribution {          // the bundled Apache-2.0 texts, for the app's credits
    public static func notice() -> String
    public static func license() -> String
}
```

**The sample shot:**
- a man and a woman walk toward each other and turn;
- a chair and a wall;
- two camera marks making a push-in;
- one middle guide.

The small variant has the same action, timed to 22 frames. Tests use the small one, except IT1. Previews
use the full one.

**Errors:** unresolved references, attachment cycles, non-finite numbers, an invalid canvas or frame
count, an unknown asset, gait or content id, and guide frames out of range. Everything else is a warning.

### 5.7 Plates, set pieces and creatures

A **location plate** is an approved still of the empty set. Its **match** is the camera that took it, in the
scene's world, with the plate's floor as the ground plane. A shot blocked over a plate starts from that
camera, so a stand-in on the floor has the size and place a person there would have.

```swift
public typealias PlateID = String
public struct LocationPlate: Codable, Sendable, Equatable, Identifiable {
    public var id: PlateID
    public var name: String
    public var file: String                 // the image's file name in <project>/Shots/Plates
    public var size: PixelSize              // the image's own pixels
    public var match: PlateMatch?           // nil until the camera has been matched
    public var guides: PlateGuides          // what the user marked, kept so the match can be corrected
    public var aspect: Double { get }
    public var hasPlainFileName: Bool { get }   // one file name, no folders: validation requires it
}
public struct PlateMatch: Codable, Sendable, Equatable {
    public var position: Vec3               // y = the camera's height above the set's floor
    public var pan: Double, tilt: Double, roll: Double
    public var focalLength: Double          // millimetres
    public var sensor: Sensor
    public static let unmatched: PlateMatch // level, 1.6 m high, 35 mm, super35
    public func camera(aspect: Double) -> CameraFrame
    public func cameraMark(id: MarkID) -> CameraMark
    public func agrees(with camera: CameraFrame) -> Bool   // within 1 cm, 0.05°, 0.1 mm of lens
    public func horizon(size: PixelSize) -> (left: Point2, right: Point2)?
}
public struct PlateLine: Codable, Sendable, Equatable { public var a: Point2, b: Point2 }
public struct PlateHeightReference: Codable, Sendable, Equatable {
    public var foot: Point2, top: Point2
    public var height: Double               // metres
}
public struct PlateGuides: Codable, Sendable, Equatable {
    public var linesA: [PlateLine]          // two edges parallel in the set and level with its floor
    public var linesB: [PlateLine]          // two more, square to the first two on the floor
    public var heightReference: PlateHeightReference?
    public var floorLevel: Double           // metres the floor this plate shows lies above the set's floor; 0
    public static let none: PlateGuides
}
public enum PlateSolve {
    public static func match(guides: PlateGuides, size: PixelSize, sensor: Sensor, focalLength: Double? = nil,
                             cameraHeight: Double? = nil, current: PlateMatch? = nil) throws -> PlateMatch
}
public enum PlateFit {      // where a plate sits on a canvas seen through the same camera; never cropped or stretched
    public struct Rect: Sendable, Equatable { public var x: Double, y: Double, width: Double, height: Double }
    public static func rect(plate: PixelSize, canvas: PixelSize, sensor: Sensor) -> Rect
    public static func widthMismatch(plate: PixelSize, canvas: PixelSize, sensor: Sensor) -> Double
}
```

- Points on a plate are fractions of its width and height from the top left.
- **Solving.** Both pairs of lines give the lens, tilt, roll and turn; one pair with a given lens gives tilt
  and turn for a level horizon; the height reference gives the camera height. `focalLength` and
  `cameraHeight` override what the guides would solve, and `current` supplies whatever they don't
  determine. The world is turned so the first pair runs along a world axis, so set pieces placed square to
  the world are square to the set. Lines that can't be solved throw `ShotsError.invalid` with a sentence
  that says what to redraw.
- **Facing.** Lines give the set's axes, not which way along them the camera looks. The solved turn is the
  one within a quarter turn of `current`'s, so a reverse plate (`current.pan` near π) stays a reverse. With
  no `current` it lies between −45° and 45°.
- **Floor level.** The set's floor is y = 0. A plate taken on a raised floor, such as a dais, has that
  floor's height in `guides.floorLevel`: its lines and height reference are marked on the raised floor,
  `cameraHeight` is measured from it, and the solved `position.y` is that height plus the level. `Staging`
  carries the level and tells the camera's height from the floor the plate shows.
- The principal point is the plate's centre: a plate must be the whole image, not a crop off-centre.

A **set piece** is a sized stand-in for part of the set. Its asset is `set.<kind>`, and its size is its own.

```swift
public struct SetPiece: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case block, plinth, dais, stairs, table, bench, throne, wall, parapet, arch, column
    }
    public var kind: Kind
    public var size: Vec3                   // width (its X), height, depth (its Z), metres at scale 1
    public var steps: Int                   // dais: steps down its front; stairs: steps in the flight
    public var inPlate: Bool                // the plate already shows it
    public static func standard(_ kind: Kind, inPlate: Bool) -> SetPiece
    public var assetID: String { get }      // "set.<kind>"
    public var isWalkable: Bool { get }     // block, plinth, dais, stairs
    public func parts() -> [PartSpec]       // its boxes; origin on the ground at its centre, front toward −Z
}
```

- A person or animal whose position is over a walkable piece stands on its top: the evaluator raises them
  to it. Nothing else is raised.
- A set piece is never an actor. It hides the actors behind it in the pose and layout passes and in the
  staging analysis.
- With `inPlate` true the piece is not drawn in a composition guide: the plate shows there. With `inPlate`
  false it is drawn as a grey box.

**Creatures.** `creature.dragon` (wings folded) and `creature.dragon.spread` are static bodies in the
category `creatures`, and actors. Scale 1 is a dragon with a skull about 1.8 m tall and wings about 30 m
across; the entity's scale sizes others. The catalog adds the set-piece and creature assets to Blockout's
and lists them in the starter set.

### 5.8 Staging

What a frame shows of each actor, from the evaluated frame alone.

```swift
public enum BodyExtent: String, Codable, Sendable, CaseIterable {
    case face, chestUp, waistUp, thighsUp, kneesUp, headToBoots
    public var phrase: String { get }       // "from mid-thigh up"
}
public struct FramingAsk: Codable, Sendable, Equatable { public var entityID: EntityID; public var extent: BodyExtent }
public enum BodyLevel: Int, Sendable, CaseIterable, Comparable {
    case crown, eyes, neck, chest, waist, hips, midThigh, knees, shins, feet
}
public struct StagedCharacter: Sendable, Equatable {
    public enum Horizontal: String, Sendable { case left, centre, right }
    public enum Depth: String, Sendable { case foreground, midground, background }
    public enum Facing: String, Sendable {
        case camera, threeQuarterLeft, threeQuarterRight, profileLeft, profileRight, awayLeft, awayRight, away
    }
    public enum Cut: Sendable, Equatable { case frame(String), hidden(by: [String]) }
    public struct Box: Sendable, Equatable { public var x: Double, y: Double, width: Double, height: Double }
    public var entityID: EntityID
    public var name: String
    public var standIn: String              // its stand-in's colour name in the composition guide
    public var isPerson: Bool, isVisible: Bool
    public var horizontal: Horizontal, depth: Depth, facing: Facing
    public var lowest: BodyLevel?           // people: the lowest level visible in an unbroken run from the head
    public var crownVisible: Bool
    public var cut: Cut?                    // what ends the visible part; nil when all of it shows
    public var visibleFraction: Double, headFraction: Double, bodyFraction: Double
    public var distance: Double             // metres from the camera along its view
    public var box: Box?                    // the visible part, in fractions of the canvas
    public var extentPhrase: String { get } // "from head to mid-thigh"
}
public struct Staging: Sendable, Equatable {
    public var shotName: String, plateName: String?
    public var canvas: ShotCanvas, camera: CameraFrame, sensor: Sensor
    public var framing: String              // "medium-full two-shot"
    public var characters: [StagedCharacter]
    public func description() -> String     // the plate, the framing, the camera, then a line per character
    public func legend() -> String          // which stand-in colour is which character
}
public enum StagingAnalysis {
    public static func characters(in frame: SceneFrame) -> [StagedCharacter]
    public static func staging(shot: Shot, frame: SceneFrame) -> Staging
}
public enum StandInPalette {                // blue, orange, green, magenta, yellow, cyan, red, purple
    public static let colors: [(name: String, color: RGB)]
    public static func standIn(_ index: Int) -> (name: String, color: RGB)   // by index among a frame's actors
}
public struct SightLines: Sendable {        // what the set pieces and props hide from the camera
    public init(frame: SceneFrame)
    public var isEmpty: Bool { get }
    public func isHidden(_ point: Vec3) -> Bool
}
public enum FramingTable {
    public struct Row: Sendable, Equatable {
        public var shotID: ShotID
        public var shot: String, plate: String, framing: String, lens: String, camera: String, who: String
    }
    public static func rows(scene: PrevisScene, catalog: ContentCatalog) -> [Row]
    public static func markdown(scene: PrevisScene, catalog: ContentCatalog) -> String
}
```

- A person is sampled at ten heights from the rig's keypoints. A sample shows when it is inside the canvas
  and no set piece or prop is between it and the camera. Other actors are sampled over their bounds.
- **Left, centre, right** is the visible part's centre across the frame, split at 0.38 and 0.62.
  **Foreground, midground, background** is the standing height against the frame's height, split at 1 and
  0.45. Facing is the heading seen from the camera, in 40° and 50° sectors.
- **Staging warnings**, from the first frame: a character less visible than the shot asks, with what hides
  or cuts them; a close shot the camera can't give, with the distance it would need; a character out of
  frame; a character standing inside furniture; a shot whose first frame has left its plate's camera; a
  plate without a match; and a canvas of another shape than its plate.

### 5.9 Blocking from a description

```swift
public struct BlockingBrief: Codable, Sendable, Equatable {
    public enum Relation: String, Codable, Sendable { case on, behind, inFrontOf }
    public enum Facing: Codable, Sendable, Equatable {       // JSON: "camera", "away", "frameLeft",
        case camera, away, frameLeft, frameRight              // "frameRight" or "toward:<name>"
        case toward(String)
    }
    public struct Character: Codable, Sendable, Equatable {
        public var name: String             // an entity of the scene by name, or a new one
        public var asset: String?           // for a new entity; nil = person.man
        public var frameX: Double?          // 0 at the frame's left edge to 1 at its right; nil = spread evenly
        public var show: BodyExtent?        // also recorded as the shot's ask
        public var relation: Relation?      // with `piece`: on, behind or in front of a set piece
        public var piece: String?
        public var facing: Facing?          // nil = the camera
    }
    public var shot: String                 // an existing shot of that name is blocked again
    public var plate: String?               // by name or id; nil = the scene's first plate
    public var characters: [Character]
}
public enum BlockingSolver {
    public static func apply(_ brief: BlockingBrief, to scene: inout PrevisScene,
                             catalog: ContentCatalog) throws -> (shotID: ShotID, notes: [String])
}
public enum BlockingReader {                // the offline reader: the scene's names and a small vocabulary
    public static func brief(from text: String, scene: PrevisScene, newCharacters: [String] = []) -> BlockingBrief
}
```

```swift
public extension PrevisScene {
    func shotsSharingBlocking(with shotID: ShotID) -> [Shot]
    @discardableResult mutating func giveOwnBlocking(to shotID: ShotID, takeID: TakeID) -> TakeID?
    mutating func pinActorsWhenTakesDiffer()
}
```

- **A shot's own blocking.** A scene may hold several takes. `giveOwnBlocking` copies the shot's take when
  another shot shares it, after pinning every unmarked actor where it stands: its placement becomes a
  standing mark at time 0, in the shared take and so in the copy. The copy's mark ids are made from
  `takeID`. An attached entity is not pinned. Once a scene has more than one take, an added actor is
  pinned in each (`pinActorsWhenTakesDiffer`), so its moves stay in the shot they are made in. The solver
  gives a brief's shot its own blocking.
- `Shot.block(over:)` puts a shot on a plate: the plate's sensor and the first camera mark on its match. A
  canvas of another shape than a 9:16 plate becomes 576 × 1024.
- The solver needs a matched plate. "Behind" is the side of the piece away from the camera. On open floor
  it tries distances and keeps the nearest at which the staging analysis shows what `show` asks, so the
  solver and the warnings agree. `notes` are the staging warnings of the result.
- A briefs file is one `BlockingBrief` or an array of them, as JSON.

## 6. ShotsMedia (Lane B)

```swift
import ConceptCore
import CoreGraphics
import Foundation
import PrevisCore
import RealityKit

public struct PrevisLook: Sendable, Equatable {     // the one canonical look for viewport and export
    public var lighting: LightingPreset
    public init(lighting: LightingPreset)
    public init(scene: PrevisScene)
}

@MainActor public final class PrevisSceneMapper {
    public let root: Entity                         // one child per PrevisEntity
    public init(look: PrevisLook)
    public func setLook(_ look: PrevisLook)
    public func apply(_ frame: SceneFrame)          // idempotent; adds, updates, removes by (entity id, part id)
    public func entityID(of entity: Entity) -> EntityID?
    public func cameraEntity(for camera: CameraFrame) -> Entity
}

@MainActor public final class ShotFrameRenderer {   // export and the look-through view both use it
    nonisolated public static var isAvailable: Bool { get }   // a Metal device exists
    public init() throws
    public func image(of frame: SceneFrame, look: PrevisLook, camera: CameraFrame? = nil,
                      overlay: Entity? = nil, size: PixelSize? = nil) async throws -> CGImage
    // camera nil = frame.camera; size nil = frame.canvas. `overlay` (editor chrome) is added as a child
    // for this render only and removed afterwards; pass a clone if it is attached elsewhere.
}

public enum PassKind: String, Codable, Sendable, CaseIterable { case clean, pose, layout, matte }
public struct ExportOptions: Sendable, Equatable {
    public var passes: Set<PassKind>
    public var plateFolder: URL?                    // the project's Shots/Plates; a plate shot needs it
    public init(passes: Set<PassKind>, plateFolder: URL? = nil)
    public static let standard: ExportOptions       // all four passes
    public static func standard(inProject project: URL) -> ExportOptions
}

@MainActor public final class PlateImages {         // plate images, read once and unchanged
    public init(folder: URL)
    public let folder: URL
    nonisolated public static func folder(inProject project: URL) -> URL   // <project>/Shots/Plates
    nonisolated public static func url(of plate: LocationPlate, in folder: URL) throws -> URL
    // The only way to a plate's image: refuses a file name that would lead out of the folder.
    public func image(for plate: LocationPlate) throws -> CGImage
    nonisolated public static func read(_ url: URL, name: String) throws -> CGImage
    nonisolated public static func pixelSize(of url: URL) -> PixelSize?
}
public struct StandInOptions: Sendable, Equatable {
    public var colored: Bool                        // each actor in its StandInPalette colour
    public var labels: Bool                         // a name tag over each actor
    public var setPieceOpacity: Double              // how strongly in-plate set pieces show; 0 = they only hide
    public static let guide: StandInOptions         // coloured, no text
    public static let labelledGuide: StandInOptions
    public static let blocking: StandInOptions      // labelled, set pieces faint, for fitting them
}
// extension ShotFrameRenderer
//   public func image(of frame: SceneFrame, over plate: CGImage, look: PrevisLook, options: StandInOptions,
//                     sensor: Sensor, size: PixelSize? = nil) async throws -> CGImage
// The plate is placed by PlateFit and covered only where a stand-in is drawn.

public enum ShotBlockingWriter {                    // reads a description into a brief with a language model
    public static func read(_ text: String, scene: PrevisScene,
                            endpoint: ResolvedEndpoint) async throws -> BlockingBrief
}
public struct ExportProgress: Sendable, Equatable { public var step: String; public var fractionCompleted: Double }
public struct ExportedPackage: Sendable { public var url: URL; public var manifest: PackageManifest }
public protocol PackageDestination: Sendable {      // the extension seam (SHOTS-PLAN section 7)
    func stagingDirectory() throws -> URL           // where the exporter builds the package
    func deliver(staged: URL, manifest: PackageManifest) async throws -> URL
}
public struct FolderDestination: PackageDestination {
    public init(parent: URL)                        // delivers to <parent>/<shot-slug>/<stamp>-<N>f-<W>x<H>/
}

@MainActor public final class ShotExporter {
    public init(catalog: ContentCatalog) throws
    public func export(scene: PrevisScene, shotID: ShotID, options: ExportOptions,
                       to destination: any PackageDestination,
                       progress: @escaping @MainActor (ExportProgress) -> Void) async throws -> ExportedPackage
    // Validates before delivering. Cancelling the Task leaves no staged or partial package.
}
public enum PackageValidator {
    public static func problems(at packageURL: URL) async -> [String]   // empty = valid (section 8.3)
}

public enum ShotPromptCompiler {
    public static func facts(scene: PrevisScene, shotID: ShotID, catalog: ContentCatalog) throws -> PromptFacts
    public static func template(_ facts: PromptFacts) -> ShotPrompt     // deterministic, offline
    public static func write(_ facts: PromptFacts, endpoint: ResolvedEndpoint) async throws -> ShotPrompt
}
public struct PromptFacts: Codable, Sendable, Equatable { /* Lane B; includes sceneRevision */ }

public enum ShotsCommandLine {              // all CLI logic; the executable only calls this
    @MainActor public static func run(arguments: [String]) async -> Int32
}
@MainActor public enum ShotsSelfTest {      // sandbox spike; Lane C wires `--shots-self-test`
    public static func run() async -> Int32 // renders and encodes the sample in the app's temp folder;
}                                           // prints a JSON report to stdout; returns an exit code
```

## 7. The app (Lanes C and D)

These types live in the `ConceptStudio` target, so they are internal, but both lanes depend on them.

```swift
enum StudioWorkspace: String, Sendable { case training, shots }
// StudioSession (C): `var workspace: StudioWorkspace` (default .training; never changes `step`)
//                    `var shots: ShotsStore?` (created when a project opens, released when it closes)

enum ShotsSelection: Equatable, Sendable {
    case none
    case entities([EntityID])
    case camera
    case actorMark(EntityID, MarkID)
    case cameraMark(MarkID)
}
enum ShotsTool: Equatable, Sendable { case select, place(assetID: String), dropMarks }

@MainActor @Observable final class ShotsStore {   // Lane C
    init(catalog: ContentCatalog, document: ShotsDocument, saveURL: URL?, readOnly: Bool = false)
    // saveURL nil = never saves (tests, previews). Starts on the first scene's first shot (nil if none), playhead 0.
    // readOnly (a newer-version shots.json): perform throws a plain sentence, and the viewport tools are disabled.
    let catalog: ContentCatalog
    var isReadOnly: Bool { get }
    private(set) var document: ShotsDocument
    var currentSceneID: SceneID?
    var currentShotID: ShotID?
    var selection: ShotsSelection
    var tool: ShotsTool
    var playhead: Int                       // frame index in the current shot
    var isPlaying: Bool
    var preview: [ShotsCommand]             // applied in order: drawn, never saved or undoable; empty between gestures
    var onError: (@MainActor (String) -> Void)?   // set by the session to show the window alert
    var currentScene: PrevisScene? { get }  // preview applied
    var currentShot: Shot? { get }
    var evaluator: ShotEvaluator? { get }   // current shot, preview applied; cached; nil when invalid
    var frame: SceneFrame? { get }          // evaluator?.frame(playhead)
    var problems: [ShotsProblem] { get }
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    func perform(_ command: ShotsCommand, coalescing: Bool = false) throws
    // Applies, bumps the scene revision (not for setPrompt), records one undo step and schedules a save.
    // coalescing: true merges into the previous step when that was the same command kind and target and
    // came within 0.8 s (inspector slider bursts). False, the default, is always its own step.
    func perform(_ commands: [ShotsCommand]) throws   // all or none, in order, as one undo step; never coalesces
    func run(_ command: ShotsCommand, coalescing: Bool = false)   // UI entry: perform, errors to onError
    func run(_ commands: [ShotsCommand])    // UI entry for a batch
    func undo()
    func redo()
    func newID(_ prefix: String) -> String
}

enum ShotsCommand: Codable, Sendable, Equatable {  // Lane C
    // Scenes and shots
    case addScene(id: SceneID, name: String, takeID: TakeID, shotID: ShotID, cameraMarkID: MarkID)
    case renameScene(SceneID, name: String)
    case deleteScene(SceneID)
    case setLighting(SceneID, LightingPreset)
    case addShot(SceneID, id: ShotID, name: String, cameraMarkID: MarkID)
    case duplicateShot(ShotID, newID: ShotID)       // the copy's camera marks get new ids
    case renameShot(ShotID, name: String)
    case deleteShot(ShotID)
    case setFrameCount(ShotID, Int)                 // snapped; drops guide frames that fall outside
    case setCanvas(ShotID, ShotCanvas)
    case setGuideFrames(ShotID, [Int])
    case setNotes(ShotID, ShotNotes)
    case setPrompt(ShotID, ShotPrompt?)             // does not bump the revision
    case importScenes([PrevisScene])                // refused if any id already exists
    // Entities
    case addEntity(SceneID, PrevisEntity)
    case setPlacement(EntityID, Placement)
    case renameEntity(EntityID, name: String)
    case setLabel(EntityID, EntityLabel?)
    case deleteEntities([EntityID])                 // removes tracks, notes and camera references; detaches children
    case attach(child: EntityID, parent: EntityID?, shot: ShotID, atFrame: Int)   // nil detaches, keeping the world pose
    // Actor marks (the take used by the shot)
    case addActorMark(ShotID, EntityID, ActorMark)
    case updateActorMark(ShotID, EntityID, ActorMark)   // matched by id
    case applyMotion(ShotID, EntityID, motionID: String, atFrame: Int)
    case overlayMotion(ShotID, EntityID, motionID: String)
    case applyActionPath(ShotID, EntityID, pathID: String, atFrame: Int, duration: Double, speed: Double?)
    // Camera
    case setCameraRig(ShotID, sensor: Sensor, rig: Rig, intensity: Double)
    case setTracking(ShotID, [EntityID])
    case setMount(ShotID, EntityID?)
    case addCameraMark(ShotID, CameraMark)
    case updateCameraMark(ShotID, CameraMark)       // matched by id
    case applyCameraMove(ShotID, moveID: String, subjects: [EntityID])
    case applyFraming(ShotID, Framing.Kind, subjects: [EntityID], atFrame: Int)
    // Either kind of mark
    case deleteMarks(ShotID, [MarkID])
    // Plates and set pieces
    case addPlate(SceneID, LocationPlate)
    case updatePlate(SceneID, LocationPlate)        // matched by id; every shot on the plate follows its camera
    case deletePlate(SceneID, PlateID)              // shots on it go back to the grey stage
    case setShotPlate(ShotID, PlateID?)             // Shot.block(over:)
    case setKeyCanvas(ShotID, ShotCanvas?)
    case setAsks(ShotID, [FramingAsk])
    case setSetPiece(EntityID, SetPiece)            // size, steps, inPlate; the kind stays
    case replaceScene(PrevisScene)                  // blocking from a description, as one step
    case giveOwnBlocking(ShotID, takeID: TakeID)    // PrevisScene.giveOwnBlocking; a used take id is refused
}
// ShotsStore: `var plateFolder: URL?` (the project's Shots/Plates, set by the session)

struct ShotsViewport: View { init(store: ShotsStore) }   // Lane D: free editor camera and interaction
struct ShotCameraView: View { init(store: ShotsStore) }  // Lane D: the shot camera, rendered as exported
```

**C0 makes `evaluator` and `frame` work from day 1.** They wrap PrevisCore, and the viewport draws
`store.frame`.

**Plates in the app.**
- `addEntity` completes a `set.<kind>` entity with its standard set piece. Over a matched plate, an entity
  added at the origin with no heading starts four metres in front of the plate's camera, facing it.
- `deleteEntities` also removes the entity's asks.
- `ShotCameraView` draws a plate shot over its plate (`StandInOptions.blocking`). A click there selects the
  stand-in under it, and a drag slides the selected one along the floor it stands on, previewed through
  `store.preview` and committed once.

**Gestures.** While dragging, the viewport sets `store.preview` to the commands it would perform: usually
one, or a batch when one gesture edits several things (dragging an actor that has marks moves its placement
and every mark in the shot's take). On mouse-up it calls `run` once, with the one command or the batch, so
the gesture is one undo step, and sets `preview` back to empty. Inspector fields that change continuously use
`coalescing: true`.

**Keyboard ownership.** Keys act on the focused region, and nothing fires while a text field is editing.

| Keys | Where | Does | Owner |
|---|---|---|---|
| Space | anywhere in Shots | play / pause | C |
| ⌘Z, ⇧⌘Z | anywhere in Shots | undo / redo | C |
| ← → (⇧ ×24), Home, End | timeline focused | step the playhead | C |
| Delete | timeline focused | delete selected marks | C |
| ← ↑ → ↓ (⇧ ×10) | viewport focused | nudge the selection 5 cm | D |
| Delete | viewport focused | delete the selection | D |
| V or Esc, M, R, G, F, C, 1–9 | viewport focused | select tool, drop marks, rotate, move, frame selection, look-through, jump to camera mark | D |

## 8. File formats

### 8.1 Project files

| File | Content | Owner |
|---|---|---|
| `<project>/.conceptstudio/shots.json` | `ShotsDocument` JSON (section 4), written with `AtomicFile` | C writes, A defines |
| `<export folder>/<shot-slug>/<YYYYMMDD-HHMMSS>-<N>f-<W>x<H>/` | one exported package | B |
| `<project>/Shots/Plates/<plate id>.<ext>` | a plate's image, copied byte for byte from the file the user chose | C |
| `<export folder>/<scene-slug>-framing.md` | a scene's framing table and each shot's staging in words | C |

The store never touches `job.yaml` or `images/`.

**Export folder.** A scene's export folder is `<project>/Shots` until the user chooses another folder for
that scene, such as the scene's folder in a production tree. The choice is not in `shots.json`: the app
keeps it in its preferences per project and scene, as a security-scoped bookmark, because it only means
something on the Mac that made it. A chosen folder that can no longer be opened is an error the user sees;
the app never falls back to `<project>/Shots` on its own. Plates stay in the project.

**Saving.**
- 0.5 s after the last edit.
- At the **start** of `releaseProject`, before folder access stops and before the demo folder is removed.
  A failed save there makes the release fail, and that failure reaches whoever asked for it.
- **Before** the app approves quitting or closing its window (`applicationShouldTerminate`,
  `windowShouldClose` and the shared path in `AppLifetime.swift`). A failed save vetoes the quit or close and
  is reported, and the existing GPU and caption confirmations stay as they are.
  `willTerminateNotification` arrives too late to veto, so it isn't the save point.

**Reading.**
- A `shots.json` that won't decode is renamed to `shots.json.unreadable-<timestamp>`, and the user is told.
- A newer version is refused with a message. The store opens with `readOnly: true` and never writes the
  file.

### 8.2 Content resources (`app/PrevisCore/Sources/PrevisCore/Resources/`)

| File | Source |
|---|---|
| `motions.v1.json`, `assets.v1.json`, `camera-moves.catalog.v1.json`, `action-presets.catalog.v1.json` | `scripts/blockout/extract.ts`, copied unchanged (the extractor also writes golden vectors, which are not resources) |
| `parts.v1.json` | authored by Lane A from Blockout's builders: `{"schema":1,"source":{…},"assets":{"<asset id>":[PartSpec…]}}` |
| `starter.v1.json` | the `StarterSet` (README lists the first set) |
| `LICENSE`, `NOTICE` | Apache-2.0 text and Blockout's NOTICE; bundled, so the app ships the attribution |

### 8.3 The shot package

```
<stamp>-<N>f-<W>x<H>/
  manifest.json
  shot.json
  prompt.txt                         only when the shot has a prompt
  prompt.json                        only when the shot has a prompt: {sections, text, facts, sceneRevision,
                                     problems}; sceneRevision is the revision the prompt was written from
                                     (facts are the scene's at export), problems are sentences such as a stale
                                     or overlong prompt
  guides/<position>-f<frame:04>-<variant>.png
  staging.txt                        the first frame's staging in words, then the stand-in legend
  staging.json                       the same as data
  control/pose.mp4
  control/layout.mp4
  mattes/<entity-slug>.mp4
  mattes/<entity-slug>-f<frame:04>.png
  reference/clean.mp4
```

`<entity-slug>` is the entity name in lowercase ASCII with dashes. When two entities share a slug, they
get `-2`, `-3`, … in entity order.

```swift
public struct PackageManifest: Codable, Sendable, Equatable {   // ShotsMedia
    public var format: String               // "conceptstudio.shot-package"
    public var formatVersion: Int           // 2; version 1 packages are still valid
    public var createdBy: String            // "ConceptStudio <version>"
    public var shot: ShotRef
    public var frameRate: Int               // 24
    public var frameCount: Int
    public var canvas: ShotCanvas
    public var passes: [PassKind]           // the passes this package was exported with
    public var files: [PackageFile]
    public var keyCanvas: ShotCanvas?       // the composition guides' size; set for a plate shot
    public var plate: PlateRef?             // the plate the shot is blocked over
}
public struct PlateRef: Codable, Sendable, Equatable {
    public var id: PlateID, name: String, file: String
    public var size: PixelSize
}
public struct ShotRef: Codable, Sendable, Equatable {
    public var id: ShotID, name: String, sceneID: SceneID
    public var sceneRevision: Int
}
public struct PackageFile: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case guide, control, matte, reference, prompt, description, staging
        case promptSections = "prompt-sections"
        case stagingData = "staging-data"
    }
    public enum Position: String, Codable, Sendable { case first, middle, last }
    public enum Variant: String, Codable, Sendable {
        case clean, pose, layout, depth     // depth reserved
        case composition                    // the plate with stand-ins, at the key's size
        case compositionLabelled = "composition-labelled"   // the same with name tags
    }
    public var role: Role
    public var path: String                 // relative, "/" separators
    public var position: Position?          // guides
    public var variant: Variant?            // guides, controls, references
    public var frame: Int?                  // stills
    public var frameCount: Int?             // videos
    public var entityID: EntityID?          // mattes
    public var entityName: String?          // mattes
}
```

**Contents,** for the passes listed in `passes` (the standard export has all four):
- **Guides:** first (frame 0), last (frame N−1) and every `guideFrames` entry, in the variant of each
  included clean, pose and layout pass.
- **Mattes** (matte pass): a video and a still at every guide frame, for each actor.
- **Controls:** a video for each included pose and layout pass.
- **Reference** (clean pass): the clean video.
- **Composition guides** (a shot blocked over a plate, whatever the passes): the plate with a coloured
  stand-in per actor, `composition`, and the same with name tags, `composition-labelled`, for the first
  frame. Also for the last frame when the blocking differs there and the camera is still the plate's.
- **Staging:** `staging.txt` and `staging.json`, always.
- **Description:** `shot.json`, always.
- **Prompt:** the prompt files, when the shot has a prompt.

**Media rules.** External tools can rely on these.
- **Stills:** PNG, 8-bit RGB, sRGB, exactly the canvas size. Composition guides are exactly the key size
  (`keyCanvas`): the shot's `keyCanvas`, or else the plate's own size.
- **composition:** the plate placed by `PlateFit`, unchanged wherever no stand-in is drawn. Each actor is the
  grey-box figure in one flat `StandInPalette` colour, in actor order, with a nose and a dark band across
  the eyes, so it shows position, size and facing and nothing of a person's look. No text. A set piece the plate already shows is not drawn and hides the
  stand-ins behind it.
- **Videos:** MP4, H.264, 8-bit 4:2:0, BT.709 tags, canvas size, exactly `frameCount` frames at a constant
  24 fps with presentation time i/24, no audio. MP4 is the v1 choice; PNG sequences could follow if Phase 0
  shows a need.
- **clean:** the canonical `PrevisLook`, with no labels, editor chrome or selection highlight.
- **pose:** black background, OpenPose COCO-18 colours, limbs and joint dots per person, limbs about
  canvas.width/160 wide. Keypoints behind the camera are left out, and so is whatever a set piece or prop
  hides: a limb is drawn only along the stretches the camera sees.
- **layout:** white background, one filled box per actor covering its projected bounds clipped to the
  canvas, and cut where a set piece or prop hides the rest of the actor. The colour comes from the label,
  or else a fixed palette in entity order.
- **Frame 0 of the controls agrees with the composition guide:** all come from one evaluation through one
  camera, and the canvas and the key have the plate's shape.
- **matte:** black background, with the actor's *visible* silhouette in white; other entities occlude it.

**`shot.json`:**

```json
{
  "formatVersion": 1,
  "shot": {"id": "…", "name": "1A", "sceneID": "…", "sceneRevision": 7, "frameCount": 124,
           "frameRate": 24, "canvas": {"width": 640, "height": 1152}},
  "guides": [{"position": "first", "frame": 0}, {"position": "middle", "frame": 61},
             {"position": "last", "frame": 123}],
  "camera": {"sensor": "super35", "rig": "sticks",
             "track": [{"frame": 0, "position": {"x": 0, "y": 1.6, "z": 6}, "pan": 0, "tilt": 0,
                        "roll": 0, "verticalFOV": 0.52, "focalLength": 35}]},
  "subjects": [{"entityID": "…", "name": "Man", "assetID": "person.man", "isActor": true,
                "marks": [{"id": "…", "time": 0, "frame": 0, "position": {"x": 0, "y": 0, "z": 0},
                           "gait": "walk"}],
                "boxes": [{"frame": 0, "x": 0.31, "y": 0.22, "width": 0.18, "height": 0.61}]}],
  "scene": {"…": "the PrevisScene exactly as stored in shots.json"}
}
```

`camera.track` has one entry per frame. `boxes` are normalised to the canvas, at the guide frames.

**The prompt text** follows MiniMax's FL2VA structure:
- **Header:** a picture-alignment sentence for Picture 1 (frame 0, at 0.00 s) and Picture 2 (the last
  frame, at `duration` seconds). Middle guides are not named as pictures.
- **Sections:** `integrated_multimodal_description`, `overall_soundscape` and `non_diegetic_music`, in that
  order, each written as `key: text` and separated by blank lines.

**The validator** checks against the manifest's own `passes`, and reports a problem when any of these
holds:
- the manifest doesn't decode, or the format or version is unknown;
- a listed file is missing;
- a still or video isn't exactly the canvas size, or a composition guide isn't exactly the key size;
- the manifest names a plate but has no first composition guide, no staging description or no key size;
- a video's frame count is wrong, or its first, middle or last presentation time is;
- for an included still-producing pass, the first or last guide is missing;
- with the matte pass included, an actor in `shot.json` has no matte;
- the frame count is off the grid.

## 9. Tests

Integration over unit, and few of both. No snapshot tests, no tests that restate data or configuration,
and no real names in fixtures.

| Test | Checkpoint | Where | Proves |
|---|---|---|---|
| IT1 | B3 | ShotsMediaTests | `twoPersonWalk()` (full size, the one full-length export) → evaluator → `ShotExporter` → `PackageValidator` clean. Pose keypoint pixels sit where `CameraFrame.project` puts them. |
| IT2 | B4 | ShotsMediaTests | `blockoutProjectJSON()` → `BlockoutImport` → set the shot to 22 frames at 320 × 576 → export → validator clean. The same through `ShotsCommandLine.run(arguments:)` with `--frames 22 --canvas 320x576`. |
| IT3 | C3 | ConceptStudioTests/Shots | Temp project → store commands (scene, two entities, marks, camera mark, then `setFrameCount` 22 and `setCanvas` 320 × 576) → save → close → reopen → equal document → export → validator clean |
| IT4 | D6 | ConceptStudioTests/Shots | Scripted viewport input on `twoPersonWalk(small: true)`: place a person, drop marks, drag with preview, commit, undo, redo → expected document. The look-through image for frame 11 equals the exported `middle-f0011-clean.png`, compared as decoded RGB. |

Each lane document lists its handful of behaviour tests.

**Parity against Blockout** is porting scaffolding. It runs only when `PREVIS_GOLDENS` or `PREVIS_VECTORS`
points at the output of `scripts/blockout/`, and uses `@testable import PrevisCore` to reach internal
Blockout-shaped entry points.

**Tests that render** are gated with
`.enabled(if: ShotFrameRenderer.isAvailable && ProcessInfo.processInfo.environment["SHOTS_SKIP_RENDER"] == nil)`.
- B1's PR must show in the CI log that render tests ran on the macOS runner. If RealityKit cannot render
  there, Lane B sets `SHOTS_SKIP_RENDER: 1` on the swift job in `ci.yml` and records why. The tests still
  run locally.
- CI kills `swift test` after 300 s, and the existing suite already uses about 150 s. So every render and
  export test uses `twoPersonWalk(small: true)` or another 22-frame, 320 × 576 shot, except IT1, which
  exports the full sample once.
- Timing tests run only with `SHOTS_TIMING=1`, in release builds on a Mac. CI never sets it. Lane B runs
  them and records the numbers in its status file, for every lane's budgets.

## 10. Budgets, runtime and toolchain

| Budget (release build, Apple silicon) | Owner |
|---|---|
| `ShotEvaluator.init` under 5 ms and `frame` under 2 ms, with 10 entities | A |
| `ShotFrameRenderer.image` under 40 ms at 640 × 1152 | B |
| Standard export of 124 frames with 2 actors under 30 s | B |
| Viewport orbit at 60 fps with 20 entities; scrubbing and playback at 24 fps | D |

The store caches its evaluator per document, shot and preview, so construction runs once per edit, not
once per read.

**Concurrency rules:**
- PrevisCore values are `Sendable`.
- RealityKit code is `@MainActor`.
- `CVPixelBuffer` isn't `Sendable` and never crosses a `Task` boundary.
- Exports run as `async` main-actor work that awaits render completions, so the UI stays live.
- All long work respects `Task` cancellation.

**Toolchain.** CI is the reference: Xcode 26.6, Swift 6.3, on a `macos-26` runner. Don't use language
features newer than that, even if your local toolchain has them. Run the linters from `app/` (the
swiftlint config lives there) and through `mise exec --`, because plain `swiftlint` may resolve to an
older Homebrew build.

**The CI gate:**
- `swift build` and `swift test` for the app;
- `swift test --package-path PrevisCore`;
- `swiftlint lint --strict` and `swiftformat --lint` over `Sources`, `Tests`, `PrevisCore/Sources` and
  `PrevisCore/Tests`.
