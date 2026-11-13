import AppKit
import PrevisCore
import ShotsMedia
import SwiftUI
import UniformTypeIdentifiers

/// The shot inspector's plate part: which plate the shot is blocked over, the plate's camera match, the size of
/// the key the image model makes, what the shot asks to show of each character, and the staging in words.
struct ShotsPlateSection: View {
    @Bindable var store: ShotsStore
    let shot: Shot
    let projectDirectory: URL?
    @State private var showsImporter = false
    @State private var matching: LocationPlate?
    @State private var renaming: LocationPlate?
    @State private var proposedName = ""
    @State private var copied = false

    private var plates: [LocationPlate] {
        store.currentScene?.plates ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Location plate").font(.headline).accessibilityAddTraits(.isHeader)
            Picker("Plate", selection: Binding(
                get: { shot.plateID ?? "" },
                set: { store.run(.setShotPlate(shot.id, $0.isEmpty ? nil : $0)) }
            )) {
                Text("None (grey stage)").tag("")
                ForEach(plates) { Text($0.name).tag($0.id) }
            }
            .help("The approved still of the empty set this shot is blocked over. The shot camera then starts "
                + "where the plate was taken from, and stand-ins are drawn over the plate.")
            HStack {
                Button("Add plate…", systemImage: "photo.badge.plus") { showsImporter = true }
                    .disabled(projectDirectory == nil)
                    .help("Choose an image of the empty set. It is copied into the project's Shots/Plates folder "
                        + "unchanged, and this shot is blocked over it.")
                if let plate = store.currentPlate {
                    Menu {
                        Button("Rename plate…") {
                            proposedName = plate.name
                            renaming = plate
                        }
                        Button("Remove plate from scene", role: .destructive) {
                            if let scene = store.currentScene { store.run(.deletePlate(scene.id, plate.id)) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Actions for plate \(plate.name)")
                    .help("Rename this plate, or remove it from the scene. Its image stays in the project folder.")
                }
            }
            if let plate = store.currentPlate {
                matchStatus(plate)
                keySize(plate)
            }
            Divider()
            blockingSharing
            let people = store.currentScene?.entities.filter { $0.assetID.hasPrefix("person.") } ?? []
            if !people.isEmpty {
                Divider()
                Text("What the shot shows").font(.headline).accessibilityAddTraits(.isHeader)
                    .help("Say how much of each character this shot is meant to show. Shots warns while you block "
                        + "if the set or the frame makes that impossible.")
                ForEach(people) { askPicker($0) }
            }
            if let staging = store.staging {
                Divider()
                stagingPanel(staging)
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.png, .jpeg, .tiff, .heic]) { result in
            addPlate(result)
        }
        .sheet(item: $matching) { plate in
            ShotsPlateMatchView(
                plate: plate, image: image(of: plate),
                onSave: { matched in
                    if let scene = store.currentScene { store.run(.updatePlate(scene.id, matched)) }
                    matching = nil
                    AccessibilityNotification.Announcement("Camera match saved for \(matched.name).").post()
                },
                onCancel: { matching = nil }
            )
        }
        .alert("Rename plate", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $proposedName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
                if var plate = renaming, !name.isEmpty, let scene = store.currentScene {
                    plate.name = name
                    store.run(.updatePlate(scene.id, plate))
                }
                renaming = nil
            }
        }
    }

    /// Which shots share this shot's blocking, and the way out of sharing.
    @ViewBuilder private var blockingSharing: some View {
        let others = (store.currentScene?.shotsSharingBlocking(with: shot.id) ?? []).filter { $0.id != shot.id }
        Text("Blocking").font(.headline).accessibilityAddTraits(.isHeader)
        if others.isEmpty {
            Text("This shot has its own blocking: moving someone here moves them in no other shot.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Shared with \(others.map(\.name).joined(separator: ", ")): moving someone here moves them "
                + "there too, so one performance is covered from several cameras.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Give this shot its own blocking") {
                store.run(.giveOwnBlocking(shot.id, takeID: store.newID("take")))
            }
            .help("Use when this shot stages people differently from the others. Everyone stays where they are "
                + "now; from then on, moves here stay in this shot.")
        }
    }

    @ViewBuilder private func matchStatus(_ plate: LocationPlate) -> some View {
        if let match = plate.match {
            let tilt = match.tilt * 180 / .pi
            Text(String(
                format: "Camera %.2f m high, %.0f° %@, %.0f mm.", match.position.y, abs(tilt),
                tilt < 0 ? "down" : "up", match.focalLength
            ))
            .font(.caption).foregroundStyle(.secondary)
            Button("Correct camera match…") { matching = plate }
                .help("Open the plate with its floor grid to check or correct where its camera is.")
        } else {
            Label(
                "Not matched yet: stand-ins have no true size on this plate.",
                systemImage: "exclamationmark.triangle"
            )
            .shotsAttention()
            Button("Match camera…") { matching = plate }
                .help("Find where the plate's camera was, so a stand-in on its floor is the right size. "
                    + "Done once for the plate and used by every shot on it.")
        }
    }

    private func keySize(_ plate: LocationPlate) -> some View {
        let own = ShotCanvas(width: plate.size.width, height: plate.size.height)
        let choices = [own] + ShotCanvas.keyPresets.filter { $0 != own }
        return Picker("Key size", selection: Binding(
            get: { shot.keyCanvas ?? own },
            set: { store.run(.setKeyCanvas(shot.id, $0 == own ? nil : $0)) }
        )) {
            ForEach(choices, id: \.self) { canvas in
                Text(canvas == own ? "\(ShotsShotSettings.canvasName(canvas)) (the plate's)"
                    : ShotsShotSettings.canvasName(canvas)).tag(canvas)
            }
        }
        .help("The size of the composition guide: the picture the image model makes the key from. "
            + "Use the size you make keys at, so nothing is resized afterwards.")
    }

    private func askPicker(_ entity: PrevisEntity) -> some View {
        Picker(entity.name, selection: Binding(
            get: { shot.asks.first { $0.entityID == entity.id }?.extent.rawValue ?? "" },
            set: { raw in
                var asks = shot.asks.filter { $0.entityID != entity.id }
                if let extent = BodyExtent(rawValue: raw) {
                    asks.append(FramingAsk(entityID: entity.id, extent: extent))
                }
                store.run(.setAsks(shot.id, asks))
            }
        )) {
            Text("No ask").tag("")
            ForEach(BodyExtent.allCases, id: \.self) { Text(Self.name(of: $0)).tag($0.rawValue) }
        }
        .help("How much of \(entity.name) this shot should show. Shots warns when the plate, the set or the frame "
            + "makes that impossible.")
    }

    private func stagingPanel(_ staging: Staging) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Staging in words").font(.headline).accessibilityAddTraits(.isHeader)
            Text("\(Self.capitalised(staging.framing)), from the frame at the playhead.")
                .font(.caption).foregroundStyle(.secondary)
            Text(staging.description()).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button(copied ? "Copied" : "Copy staging", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(staging.description() + "\n\n" + staging.legend(), forType: .string)
                copied = true
                AccessibilityNotification.Announcement("Staging copied.").post()
            }
            .help("Copy this description and the stand-in legend, to paste into a key prompt or the scene sheet.")
            .onChange(of: staging) { _, _ in copied = false }
            let warnings = store.problems.filter { $0.shotID == shot.id && $0.severity == .warning }
                .map(\.message).filter(Self.isStagingWarning)
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").shotsAttention()
            }
        }
    }

    static func capitalised(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The warnings that are about what the frame can show, which belong beside the staging.
    static func isStagingWarning(_ message: String) -> Bool {
        ["asks for", "doesn't show", "stands inside", "plate"].contains { message.contains($0) }
    }

    static func name(of extent: BodyExtent) -> String {
        switch extent {
        case .face: "Close-up of the face"
        case .chestUp: "Chest up"
        case .waistUp: "Waist up"
        case .thighsUp: "Mid-thigh up"
        case .kneesUp: "Knees up"
        case .headToBoots: "Head to boots"
        }
    }

    private func image(of plate: LocationPlate) -> CGImage? {
        guard let folder = store.plateFolder else { return nil }
        return try? PlateImages.read(folder.appendingPathComponent(plate.file), name: plate.name)
    }

    private func addPlate(_ result: Result<URL, any Error>) {
        guard let projectDirectory else { return }
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let id = try store.addPlate(from: url, projectDirectory: projectDirectory)
            // Straight to the match: a plate without one has no floor to stand on.
            matching = store.currentScene?.plates.first { $0.id == id }
        } catch CocoaError.userCancelled {
            // Cancelling the file picker is not a failure.
        } catch {
            store.onError?(error.localizedDescription)
        }
    }
}

/// A set piece's own fields in the entity inspector: its size, its steps and whether the plate already shows it.
struct ShotsSetPieceFields: View {
    let store: ShotsStore
    let entity: PrevisEntity
    let piece: SetPiece

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set piece").font(.headline).accessibilityAddTraits(.isHeader)
            size("Width (m)", \.x, "How wide it is, left to right as it faces you, in metres.")
            size("Height (m)", \.y, "How tall it is, in metres. People stand on a dais, steps, a plinth or a block.")
            size("Depth (m)", \.z, "How deep it is, front to back, in metres.")
            if piece.kind == .dais || piece.kind == .stairs {
                Stepper("Steps: \(piece.steps)", value: Binding(get: { piece.steps }, set: { steps in
                    var changed = piece
                    changed.steps = steps
                    store.run(.setSetPiece(entity.id, changed), coalescing: true)
                }), in: (piece.kind == .stairs ? 1 : 0) ... 60)
                    .help(piece.kind == .dais ? "How many steps lead up to the dais at its front."
                        : "How many steps the flight has.")
            }
            Toggle("Already in the plate", isOn: Binding(get: { piece.inPlate }, set: { inPlate in
                var changed = piece
                changed.inPlate = inPlate
                store.run(.setSetPiece(entity.id, changed))
            }))
            .help("On: the plate already shows this, so it only hides the stand-ins behind it and the plate shows "
                + "through. Off: the plate lacks it, so it is drawn as a grey box in the guide.")
        }
    }

    private func size(_ title: String, _ axis: WritableKeyPath<Vec3, Double>, _ explanation: String) -> some View {
        ShotsNumberField(title: title, value: Binding(get: { piece.size[keyPath: axis] }, set: { value in
            var changed = piece
            changed.size[keyPath: axis] = value
            store.run(.setSetPiece(entity.id, changed), coalescing: true)
        }), range: 0.02 ... 500, explanation: explanation)
    }
}
