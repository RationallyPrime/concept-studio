import PrevisCore
import SwiftUI

/// Selection-driven panels follow Blockout Inspector.tsx:65–120. All choices also work without viewport input.
struct ShotsInspectorView: View {
    let store: ShotsStore
    let session: StudioSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.currentShot != nil { selectionMenu }
            inspectorContent.disabled(store.isReadOnly)
        }
    }

    @ViewBuilder private var inspectorContent: some View {
        if let scene = store.currentScene, let shot = store.currentShot {
            switch store.selection {
            case .none:
                ShotsShotInspector(store: store, session: session, shot: shot)
            case .camera:
                ShotsCameraInspector(store: store, shot: shot)
            case let .entities(ids):
                if let entity = scene.entities.first(where: { ids.contains($0.id) }) {
                    if ids.count > 1 {
                        // Above the fields, so it is read before them rather than below the fold.
                        Text("\(ids.count) selected. Editing \(entity.name); choose another from Inspect to edit it.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ShotsEntityInspector(store: store, entity: entity, shot: shot)
                }
            case let .actorMark(entityID, markID):
                if let mark = scene.blocking.first(where: { $0.id == shot.blockingTakeID })?
                    .tracks.first(where: { $0.entityID == entityID })?.marks.first(where: { $0.id == markID }) {
                    ShotsActorMarkInspector(store: store, shot: shot, entityID: entityID, mark: mark)
                }
            case let .cameraMark(markID):
                if let mark = shot.camera.marks.first(where: { $0.id == markID }) {
                    ShotsCameraMarkInspector(store: store, shot: shot, mark: mark)
                }
            }
        } else {
            Text("Choose a shot in Scenes and shots, or add a scene, to see its settings here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectionMenu: some View {
        Menu("Inspect") {
            Button("Shot") { store.selection = .none }
            Button("Camera") { store.selection = .camera }
            ForEach(store.currentScene?.entities ?? []) { entity in
                Button(entity.name) { store.selection = .entities([entity.id]) }
            }
            if let shot = store.currentShot {
                Menu("Camera marks") {
                    ForEach(shot.camera.marks) { mark in
                        Button("\(mark.time, specifier: "%.2f") s") { store.selection = .cameraMark(mark.id) }
                    }
                }
                if let take = store.currentScene?.blocking.first(where: { $0.id == shot.blockingTakeID }) {
                    ForEach(take.tracks, id: \.entityID) { track in
                        let name = store.currentScene?.entities.first { $0.id == track.entityID }?.name
                        Menu(name.map { "\($0) marks" } ?? "Actor marks") {
                            ForEach(track.marks) { mark in
                                Button("\(mark.time, specifier: "%.2f") s") {
                                    store.selection = .actorMark(track.entityID, mark.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        .help("Choose what the inspector edits: the shot, its camera, a person or prop, or one of their marks.")
        .accessibilityLabel("Inspect shot, camera, entity or mark")
        .accessibilityValue(store.inspectedDescription)
    }
}
