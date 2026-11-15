import PrevisCore
import SwiftUI
import UniformTypeIdentifiers

struct ShotsPlateInspector: View {
    @Bindable var store: ShotsStore
    @State private var importing = false
    @State private var selectedPieceID: String?
    @State private var point = Point2(x: 50, y: 70)

    var body: some View {
        if let frame = store.frame, let shot = store.currentShot, let scene = store.currentScene {
            ForEach(
                Array(PlateDiagnostics.problems(frame: frame, shot: shot, sceneID: scene.id).enumerated()),
                id: \.offset
            ) { _, problem in
                Label(problem.message, systemImage: "exclamationmark.triangle").shotsAttention()
            }
        }
        DisclosureGroup("Location plate") {
            VStack(alignment: .leading, spacing: 10) {
                if let scene = store.currentScene, let shot = store.currentShot {
                    Picker("Plate", selection: Binding(
                        get: { shot.plateID ?? "" },
                        set: {
                            if $0.isEmpty { store.run(.setPlate(shot.id, nil)) } else { store.run([
                                .setPlate(shot.id, $0),
                                .matchPlateCamera(shot.id),
                            ]) }
                        }
                    )) {
                        Text("Grey stage").tag("")
                        ForEach(scene.plates) { plate in Text(plate.name).tag(plate.id) }
                    }
                    .help("Choose a saved viewpoint and reset this shot's camera to its match.")
                    Button("Import location plate…", systemImage: "photo.badge.plus") { importing = true }
                        .disabled(store.plateRootURL == nil)
                    if let plate = store.currentPlate {
                        plateControls(plate, scene: scene, shot: shot)
                    }
                }
            }
            .padding(.top, 8)
            .disabled(store.isReadOnly)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            do { try store.importPlate(from: result.get()) } catch { store.onError?(error.localizedDescription) }
        }
    }

    private func plateControls(_ plate: LocationPlate, scene: PrevisScene, shot: Shot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(plate.pixelSize.width) × \(plate.pixelSize.height) original pixels")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Show floor and set guides", isOn: $store.showsPlateCalibration)
            DisclosureGroup("Match camera to plate") {
                calibrationControls(plate, scene: scene, shot: shot)
            }
            Button("Reset shot camera to plate") { store.run(.matchPlateCamera(shot.id)) }
                .help("Replace this shot's camera move with the saved location viewpoint.")
            Picker("Required framing", selection: Binding(
                get: { shot.requestedFraming?.rawValue ?? "" },
                set: { store.run(.setRequestedFraming(shot.id, Framing.Kind(rawValue: $0))) }
            )) {
                Text("Observe current framing").tag("")
                ForEach(Framing.Kind.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
            }
            keyCanvasControls(shot)
            DisclosureGroup("Set occlusion and platforms") {
                setControls(scene: scene)
            }
            DisclosureGroup("Place selected on plate") { placementControls(plate) }
            if let frame = store.frame {
                if frame.usesProjectedLocation {
                    Text(
                        "This camera uses the photographed floor and set surfaces from the calibrated views. "
                            + "A checker pattern marks missing coverage. Add a view or mark the missing set surface."
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(ShotStaging.description(frame: frame, shot: shot))
                    .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func calibrationControls(_ plate: LocationPlate, scene: PrevisScene, shot: Shot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "Align the one-metre grid and 1.8 m marker with the photograph. "
                    + "Set the lens and horizon, then confirm. Editing the match updates this shot's camera."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Sensor", selection: calibrationBinding(plate, scene: scene, shot: shot, \.sensor)) {
                ForEach(Sensor.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            ShotsPositionFields(
                position: calibrationBinding(plate, scene: scene, shot: shot, \.position),
                commitOnSubmit: true
            )
            ShotsNumberField(
                title: "Lens (mm)",
                value: calibrationBinding(plate, scene: scene, shot: shot, \.focalLength),
                range: 1 ... 1000, commitOnSubmit: true
            )
            angleField("Pan (°)", plate: plate, scene: scene, shot: shot, keyPath: \.pan)
            angleField("Tilt (°)", plate: plate, scene: scene, shot: shot, keyPath: \.tilt)
            angleField("Roll (°)", plate: plate, scene: scene, shot: shot, keyPath: \.roll)
            Toggle("Camera match confirmed", isOn: Binding(
                get: { plate.calibration.confirmed },
                set: { value in
                    var updated = plate
                    updated.calibration.confirmed = value
                    store.run(.putPlate(scene.id, updated))
                }
            ))
            Text(
                "Reset another shot's camera to this plate to apply its saved match."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func calibrationBinding<Value>(
        _ plate: LocationPlate, scene: PrevisScene, shot: Shot,
        _ keyPath: WritableKeyPath<PlateCalibration, Value>
    ) -> Binding<Value> {
        Binding(get: { plate.calibration[keyPath: keyPath] }, set: { value in
            var updated = plate
            updated.calibration[keyPath: keyPath] = value
            updated.calibration.confirmed = false
            store.run([.putPlate(scene.id, updated), .matchPlateCamera(shot.id)])
        })
    }

    private func angleField(
        _ name: String, plate: LocationPlate, scene: PrevisScene, shot: Shot,
        keyPath: WritableKeyPath<PlateCalibration, Double>
    ) -> some View {
        let radians = calibrationBinding(plate, scene: scene, shot: shot, keyPath)
        return ShotsNumberField(title: name, value: Binding(
            get: { radians.wrappedValue * 180 / .pi },
            set: { radians.wrappedValue = $0 * .pi / 180 }
        ), range: -180 ... 180, commitOnSubmit: true)
    }

    private func keyCanvasControls(_ shot: Shot) -> some View {
        Picker("Key size", selection: Binding(
            get: { shot.keyCanvas ?? shot.canvas }, set: { store.run(.setKeyCanvas(shot.id, $0)) }
        )) {
            ForEach(Array(Set(ShotCanvas.keyPresets + [shot.guideCanvas])).filter {
                abs($0.aspect - shot.canvas.aspect) < 1e-9
            }.sorted {
                $0.width < $1.width
            }, id: \.self) { canvas in
                Text(ShotsShotSettings.canvasName(canvas)).tag(canvas)
            }
        }
        .help("Composition guide size. The control videos use the shot's Canvas setting.")
    }

    private func setControls(scene: PrevisScene) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "Fit boxes to the table, steps, plinth and walls. "
                    + "Occluders hide figures. Platforms provide a standing height. All views share these solids."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Set piece", selection: $selectedPieceID) {
                Text("Choose a set piece").tag(String?.none)
                ForEach(scene.setPieces) { Text($0.name).tag(Optional($0.id)) }
            }
            HStack {
                Button("Add occluder") { addPiece(scene: scene, platform: false) }
                Button("Add platform") { addPiece(scene: scene, platform: true) }
            }
            if let piece = scene.setPieces.first(where: { $0.id == selectedPieceID }) {
                ShotsTextField(title: "Name", text: pieceBinding(piece: piece, scene: scene, \.name))
                ShotsPositionFields(
                    position: pieceBinding(piece: piece, scene: scene, \.position),
                    commitOnSubmit: true
                )
                ShotsNumberField(
                    title: "Width (m)",
                    value: pieceBinding(piece: piece, scene: scene, \.size.x),
                    range: 0.01 ... 1000, commitOnSubmit: true
                )
                ShotsNumberField(
                    title: "Height (m)",
                    value: pieceBinding(piece: piece, scene: scene, \.size.y),
                    range: 0.01 ... 1000, commitOnSubmit: true
                )
                ShotsNumberField(
                    title: "Depth (m)",
                    value: pieceBinding(piece: piece, scene: scene, \.size.z),
                    range: 0.01 ... 1000, commitOnSubmit: true
                )
                Toggle("Hides figures behind it", isOn: pieceBinding(piece: piece, scene: scene, \.occludes))
                Toggle("People can stand on top", isOn: pieceBinding(piece: piece, scene: scene, \.supportsStanding))
                Button("Remove set piece", role: .destructive) {
                    store.run(.removeSetPiece(scene.id, piece.id))
                }
            }
        }.padding(.top, 8)
    }

    private func pieceBinding<Value>(
        piece: PlateSetPiece, scene: PrevisScene,
        _ keyPath: WritableKeyPath<PlateSetPiece, Value>
    ) -> Binding<Value> {
        Binding(get: { piece[keyPath: keyPath] }, set: { value in
            var updated = piece
            updated[keyPath: keyPath] = value
            store.run(.putSetPiece(scene.id, updated), coalescing: true)
        })
    }

    private func addPiece(scene: PrevisScene, platform: Bool) {
        let id = store.newID("set")
        let piece = PlateSetPiece(
            id: id, name: platform ? "Dais" : "Table", position: .zero,
            size: platform ? Vec3(4, 0.6, 3) : Vec3(4, 1, 1),
            occludes: true, supportsStanding: platform
        )
        store.run(.putSetPiece(scene.id, piece))
        selectedPieceID = id
        store.showsPlateCalibration = true
    }

    private func placementControls(_ plate: LocationPlate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "Select a person and click the floor or a platform in Shot camera. "
                    + "The percentages provide the same action from the keyboard."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ShotsNumberField(title: "Across (%)", value: $point.x, range: 0 ... 100, commitOnSubmit: true)
            ShotsNumberField(title: "Down (%)", value: $point.y, range: 0 ... 100, commitOnSubmit: true)
            Button("Place selected here") {
                guard let frame = store.frame,
                      let position = plate.placementPoint(
                          at: Point2(
                              x: point.x * Double(frame.canvas.width) / 100,
                              y: point.y * Double(frame.canvas.height) / 100
                          ), size: frame.canvas.pixelSize,
                          setPieces: frame.setPieces, camera: frame.camera
                      ) else { return }
                store.moveSelectedToPlatePoint(position)
            }.disabled(store.selection.entityIDs.isEmpty)
            Button("Stand selected on surface") {
                guard let frame = store.frame, let id = store.selection.entityIDs.first,
                      let entity = frame.entities.first(where: { $0.id == id }) else { return }
                var position = entity.position
                position.y = plate.surfaceHeight(at: position, setPieces: frame.setPieces)
                store.moveSelectedToPlatePoint(position)
            }.disabled(store.selection.entityIDs.isEmpty)
        }.padding(.top, 8)
    }
}
