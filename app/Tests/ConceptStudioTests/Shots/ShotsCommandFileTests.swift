import ConceptCore
@testable import ConceptStudio
import Foundation
import PrevisCore
import Testing

@MainActor
struct ShotsCommandFileTests {
    @Test func commandFileCreatesANativeProjectAndRejectsAnInvalidBatchAtomically() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shots-cli-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("project")
        let script = folder.appendingPathComponent("commands.json")
        let catalog = try ContentCatalog.bundled()
        let commands: [ShotsCommand] = [
            .addScene(id: "scene", name: "Courtyard", takeID: "take", shotID: "shot", cameraMarkID: "camera"),
            .addEntity("scene", PrevisEntity(
                id: "squad", assetID: "person.man", name: "Squad",
                placement: Placement(position: .zero, heading: 0, scale: 1),
                formation: Formation(rows: 3, columns: 7, rowSpacing: 0.8, columnSpacing: 0.8)
            )),
            .setDialogue("shot", [DialogueLine(id: "line", startFrame: 2, text: "  Hold there.  ")]),
        ]
        try JSONEncoder().encode(commands).write(to: script)
        let url = try ShotsCommandFile.apply(script, to: project, catalog: catalog)
        let opened = try await StudioProject.open(at: project)
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let session = StudioSession(preferences: preferences.defaults, secrets: MemorySecretStore())
        session.loadShots(for: opened)
        let store = try #require(session.shots)
        #expect(store.currentScene?.entities.first?.formation?.rows == 3)
        #expect(store.currentScene?.entities.first?.formation?.columns == 7)
        #expect(store.currentShot?.dialogue.first?.text == "  Hold there.  ")
        try store.perform(.renameShot("shot", name: "Wide"))
        try store.flush()
        let before = try Data(contentsOf: url)
        try JSONEncoder().encode([.renameShot("shot", name: "Changed"), .deleteShot("unknown")] as [ShotsCommand])
            .write(to: script)
        #expect(throws: ShotsEditingError.self) {
            try ShotsCommandFile.apply(script, to: project, catalog: catalog)
        }
        #expect(try Data(contentsOf: url) == before)
    }
}
