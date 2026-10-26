import Foundation
import PrevisCore

extension StudioSession {
    func loadShots(for project: StudioProject) {
        do {
            let catalog = try ContentCatalog.bundled()
            let url = ShotsDocumentFile.url(in: project.directory)
            let existed = FileManager.default.fileExists(atPath: url.path)
            let loaded = try ShotsDocumentFile.load(from: url)
            let document = demoMode && !existed ? ShotsSamples.twoPersonWalk() : loaded.document
            let store = ShotsStore(catalog: catalog, document: document, saveURL: url, readOnly: loaded.readOnly)
            store.onError = { [weak self] in self?.errorMessage = $0 }
            shots = store
            if let notice = loaded.notice { errorMessage = notice }
        } catch {
            shots = nil
            errorMessage = Self.describe(error)
        }
    }

    func flushShots() -> Bool {
        do {
            try shots?.flush()
            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }
}
