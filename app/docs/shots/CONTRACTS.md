# Shots contracts

This file is the single source of truth for everything that crosses a lane boundary: packages and
targets, file ownership, libraries, conventions, the public Swift API between lanes, file formats and the
integration tests. Inside its own files a lane is free to design as it likes. At these seams it is not.

Read with: [README.md](README.md) (lanes, schedule), [../SHOTS-PLAN.md](../SHOTS-PLAN.md) (why).

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
| Metal (resources RealityKit needs; no `.metal` shader files), CoreVideo, CoreMedia, AVFoundation, CoreGraphics, ImageIO, UniformTypeIdentifiers | B |
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
- **Time.**
  - H3 runs at 24 fps. A shot stores a frame count on the grid 17k+5 (5, 22, 39, …, 124, …, 362).
  - Frame *i* samples t = i/24, and the last frame samples t = (N−1)/24, the shot's `duration`.
  - Marks carry seconds; the UI snaps them to frames.
- **Pixels.** Origin at the top left, y down.
  - A **shot canvas** is width × height in multiples of 32, within 64…2048. The default is 640 × 1152.
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
    public static let portrait: ShotCanvas  // 640 × 1152, the default
    public static let presets: [ShotCanvas] // 640×1152, 768×1344, 1152×640, 1344×768, 768×768
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
    public static let currentVersion: Int   // 1
    public var version: Int
    public var scenes: [PrevisScene]
}

public struct PrevisScene: Codable, Sendable, Equatable, Identifiable {
    public var id: SceneID
    public var name: String
    public var revision: Int                // bumped by the store on every edit except setPrompt
    public var lighting: LightingPreset
    public var entities: [PrevisEntity]
    public var blocking: [BlockingTake]     // v1: exactly one take, shared by the scene's shots
    public var shots: [Shot]
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
    public var duration: Double { get }     // Double(frameCount - 1) / 24
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
    public func warnings() -> [ShotsProblem]           // speed, 180° line, trained range, marks past the end
    public func paths() -> [MotionPath]                // for ribbons and spike marks
}
public struct SceneFrame: Sendable, Equatable {
    public var index: Int?                  // set when evaluated on the grid
    public var time: Double
    public var canvas: ShotCanvas
    public var camera: CameraFrame          // field of view for the canvas aspect
    public var entities: [EntityFrame]      // document order
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
    public var isActor: Bool                // rigged asset or labelled: gets a matte and a layout box
    public var position: Vec3
    public var heading: Double
    public var gait: Gait
    public var speed: Double
    public var distanceTravelled: Double
    public var joints: [Joint: Double]      // evaluated pose overrides, before the gait pose
    public var parts: [PosedPart]
    public var keypoints: [Keypoint]        // COCO-18 world positions; empty unless rig == .person
    public var bounds: Box3
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
    public static let standard: ExportOptions       // all four passes
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
    var preview: ShotsCommand?              // drawn, never saved or undoable; nil between gestures
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
    func run(_ command: ShotsCommand, coalescing: Bool = false)   // UI entry: perform, errors to onError
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
}

struct ShotsViewport: View { init(store: ShotsStore) }   // Lane D: free editor camera and interaction
struct ShotCameraView: View { init(store: ShotsStore) }  // Lane D: the shot camera, rendered as exported
```

**C0 makes `evaluator` and `frame` work from day 1.** They wrap PrevisCore, and the viewport draws
`store.frame`.

**Gestures.** While dragging, the viewport sets `store.preview` to the command it would perform. On
mouse-up it calls `run` once and sets `preview` back to nil. Inspector fields that change continuously use
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
| `<project>/Shots/<shot-slug>/<YYYYMMDD-HHMMSS>-<N>f-<W>x<H>/` | one exported package | B |

The store never touches `job.yaml` or `images/`.

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
    public var formatVersion: Int           // 1
    public var createdBy: String            // "ConceptStudio <version>"
    public var shot: ShotRef
    public var frameRate: Int               // 24
    public var frameCount: Int
    public var canvas: ShotCanvas
    public var passes: [PassKind]           // the passes this package was exported with
    public var files: [PackageFile]
}
public struct ShotRef: Codable, Sendable, Equatable {
    public var id: ShotID, name: String, sceneID: SceneID
    public var sceneRevision: Int
}
public struct PackageFile: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case guide, control, matte, reference, prompt, description
        case promptSections = "prompt-sections"
    }
    public enum Position: String, Codable, Sendable { case first, middle, last }
    public enum Variant: String, Codable, Sendable { case clean, pose, layout, depth }   // depth reserved
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
- **Description:** `shot.json`, always.
- **Prompt:** the prompt files, when the shot has a prompt.

**Media rules.** External tools can rely on these.
- **Stills:** PNG, 8-bit RGB, sRGB, exactly the canvas size.
- **Videos:** MP4, H.264, 8-bit 4:2:0, BT.709 tags, canvas size, exactly `frameCount` frames at a constant
  24 fps with presentation time i/24, no audio. MP4 is the v1 choice; PNG sequences could follow if Phase 0
  shows a need.
- **clean:** the canonical `PrevisLook`, with no labels, editor chrome or selection highlight.
- **pose:** black background, OpenPose COCO-18 colours, limbs and joint dots per person, limbs about
  canvas.width/160 wide. Keypoints behind the camera are left out.
- **layout:** white background, one filled box per actor covering its projected bounds clipped to the
  canvas. The colour comes from the label, or else a fixed palette in entity order.
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
- a still or video isn't exactly the canvas size;
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
