import Foundation
import Observation
import PrevisCore

enum ShotsEditingError: Error, LocalizedError {
    case readOnly
    case missing(String)
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case .readOnly: "This Shots file needs a newer version of ConceptStudio. Update the app to edit it."
        case let .missing(name): "The \(name) is no longer in this project. Select it again and retry."
        case let .duplicate(id): "The identifier \(id) is already in this project. Create a new item instead."
        }
    }
}

@MainActor @Observable
final class ShotsStore {
    let catalog: ContentCatalog
    private(set) var document: ShotsDocument
    let isReadOnly: Bool
    var currentSceneID: SceneID?
    var currentShotID: ShotID?
    var selection = ShotsSelection.none
    var tool = ShotsTool.select
    private var playheadIndex = 0
    var playhead: Int {
        get { min(max(0, playheadIndex), max(0, (currentShot?.frameCount ?? 1) - 1)) }
        set { playheadIndex = min(max(0, newValue), max(0, (currentShot?.frameCount ?? 1) - 1)) }
    }

    var isPlaying = false
    var preview: ShotsCommand?
    var onError: (@MainActor (String) -> Void)?

    @ObservationIgnored private let saveURL: URL?
    private var undoDocuments: [ShotsDocument] = []
    private var redoDocuments: [ShotsDocument] = []
    @ObservationIgnored private var lastEdit: (key: ShotsCoalescingKey, time: ContinuousClock.Instant)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var cachedScene: PrevisScene?
    @ObservationIgnored private var cachedShotID: ShotID?
    @ObservationIgnored private var cachedEvaluator: ShotEvaluator?

    init(catalog: ContentCatalog, document: ShotsDocument, saveURL: URL?, readOnly: Bool = false) {
        self.catalog = catalog
        self.document = document
        self.saveURL = saveURL
        isReadOnly = readOnly
        currentSceneID = document.scenes.first?.id
        currentShotID = document.scenes.first?.shots.first?.id
    }

    private var visibleDocument: ShotsDocument {
        guard let preview, !isReadOnly else { return document }
        var candidate = document
        do {
            try ShotsCommandApplication.apply(preview, to: &candidate, catalog: catalog)
            return candidate
        } catch {
            return document
        }
    }

    var currentScene: PrevisScene? {
        visibleDocument.scenes.first { $0.id == currentSceneID }
    }

    var currentShot: Shot? {
        currentScene?.shots.first { $0.id == currentShotID }
    }

    var evaluator: ShotEvaluator? {
        guard let scene = currentScene, let shotID = currentShotID else { return nil }
        if cachedScene != scene || cachedShotID != shotID {
            cachedScene = scene
            cachedShotID = shotID
            cachedEvaluator = try? ShotEvaluator(scene: scene, shotID: shotID, catalog: catalog)
        }
        return cachedEvaluator
    }

    var frame: SceneFrame? {
        evaluator?.frame(playhead)
    }

    var canUndo: Bool {
        !isReadOnly && !undoDocuments.isEmpty
    }

    var canRedo: Bool {
        !isReadOnly && !redoDocuments.isEmpty
    }

    var problems: [ShotsProblem] {
        var candidate = document
        if let preview, !isReadOnly {
            do {
                try ShotsCommandApplication.apply(preview, to: &candidate, catalog: catalog)
            } catch {
                return [ShotsProblem(severity: .error, message: error.localizedDescription)]
            }
        }
        return ShotsValidation.problems(in: candidate, catalog: catalog) + (evaluator?.warnings() ?? [])
    }

    func perform(_ command: ShotsCommand, coalescing: Bool = false) throws {
        try perform([command], coalescingKey: command.coalescingKey, coalescing: coalescing)
    }

    func perform(_ commands: [ShotsCommand]) throws {
        try perform(commands, coalescingKey: nil, coalescing: false)
    }

    private func perform(
        _ commands: [ShotsCommand],
        coalescingKey key: ShotsCoalescingKey?,
        coalescing: Bool
    ) throws {
        guard !isReadOnly else { throw ShotsEditingError.readOnly }
        guard !commands.isEmpty else { return }
        let before = document
        var candidate = before
        for command in commands {
            try ShotsCommandApplication.apply(command, to: &candidate, catalog: catalog)
        }
        guard candidate != before else { preview = nil; return }
        let failures = ShotsValidation.problems(in: candidate, catalog: catalog).filter { $0.severity == .error }
        guard failures.isEmpty else { throw ShotsError.invalid(failures) }
        let hasSceneMutation = commands.contains { command in
            if case .setPrompt = command { return false }
            return true
        }
        if hasSceneMutation {
            for index in candidate.scenes.indices {
                let scene = candidate.scenes[index]
                if let previous = before.scenes.first(where: { $0.id == scene.id }) {
                    if previous != scene { candidate.scenes[index].revision = previous.revision + 1 }
                } else {
                    candidate.scenes[index].revision += 1
                }
            }
        }
        let now = ContinuousClock.now
        let joinsPrevious = coalescing && key != nil && lastEdit?.key == key
            && lastEdit.map { $0.time.duration(to: now) <= .milliseconds(800) } == true
        if !joinsPrevious {
            undoDocuments.append(before)
            if undoDocuments.count > 200 { undoDocuments.removeFirst() }
        }
        lastEdit = key.map { ($0, now) }
        redoDocuments.removeAll()
        document = candidate
        preview = nil
        reconcileSelection()
        scheduleSave()
    }

    func run(_ command: ShotsCommand, coalescing: Bool = false) {
        do {
            try perform(command, coalescing: coalescing)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    func run(_ commands: [ShotsCommand]) {
        do {
            try perform(commands)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    func undo() {
        guard canUndo, let previous = undoDocuments.popLast() else { return }
        redoDocuments.append(document)
        document = previous
        historyDidChange()
    }

    func redo() {
        guard canRedo, let next = redoDocuments.popLast() else { return }
        undoDocuments.append(document)
        document = next
        historyDidChange()
    }

    func newID(_ prefix: String) -> String {
        PrevisIDs.make(prefix)
    }

    func flush() throws {
        saveTask?.cancel()
        saveTask = nil
        guard dirty, !isReadOnly, let saveURL else { return }
        try ShotsDocumentFile.save(document, to: saveURL)
        dirty = false
    }

    private func historyDidChange() {
        preview = nil
        lastEdit = nil
        reconcileSelection()
        scheduleSave()
    }

    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        guard saveURL != nil else { return }
        saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                try self?.flush()
            } catch is CancellationError {} catch {
                self?.onError?(error.localizedDescription)
            }
        }
    }

    private func reconcileSelection() {
        if !document.scenes.contains(where: { $0.id == currentSceneID }) {
            currentSceneID = document.scenes.first?.id
        }
        if currentScene?.shots.contains(where: { $0.id == currentShotID }) != true {
            currentShotID = currentScene?.shots.first?.id
        }
        playhead = min(max(0, playhead), max(0, (currentShot?.frameCount ?? 1) - 1))
        guard let scene = currentScene else { selection = .none; return }
        switch selection {
        case .none: break
        case .camera: if currentShot == nil { selection = .none }
        case let .entities(ids):
            let kept = ids.filter { id in scene.entities.contains { $0.id == id } }
            selection = kept.isEmpty ? .none : .entities(kept)
        case let .actorMark(entityID, markID):
            let take = scene.blocking.first { $0.id == currentShot?.blockingTakeID }
            let found = take?.tracks.first { $0.entityID == entityID }?.marks.contains { $0.id == markID }
            if found != true { selection = .none }
        case let .cameraMark(markID):
            if currentShot?.camera.marks.contains(where: { $0.id == markID }) != true { selection = .none }
        }
    }
}

enum ShotsCoalescingKey: Equatable {
    case placement(EntityID), label(EntityID), entityName(EntityID), lighting(SceneID)
    case frames(ShotID), canvas(ShotID), notes(ShotID), cameraRig(ShotID)
    case actorMark(ShotID, EntityID, MarkID), cameraMark(ShotID, MarkID)
}

extension ShotsCommand {
    var coalescingKey: ShotsCoalescingKey? {
        switch self {
        case let .setPlacement(id, _): .placement(id)
        case let .setLabel(id, _): .label(id)
        case let .renameEntity(id, _): .entityName(id)
        case let .setLighting(id, _): .lighting(id)
        case let .setFrameCount(id, _): .frames(id)
        case let .setCanvas(id, _): .canvas(id)
        case let .setNotes(id, _): .notes(id)
        case let .setCameraRig(id, _, _, _): .cameraRig(id)
        case let .updateActorMark(shot, entity, mark): .actorMark(shot, entity, mark.id)
        case let .updateCameraMark(shot, mark): .cameraMark(shot, mark.id)
        default: nil
        }
    }
}
