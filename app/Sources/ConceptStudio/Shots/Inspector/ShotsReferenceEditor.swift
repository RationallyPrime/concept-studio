import PrevisCore
import SwiftUI
import UniformTypeIdentifiers

struct ShotsReferenceEditor: View {
    let store: ShotsStore
    let shot: Shot
    @State private var importing = false

    var body: some View {
        DisclosureGroup("Camera reference") {
            if let reference = shot.reference {
                Slider(value: Binding(get: { reference.opacity }, set: {
                    store.run(
                        .setReference(shot.id, ShotReference(fileName: reference.fileName, opacity: $0)),
                        coalescing: true
                    )
                }), in: 0 ... 1) {
                    Text("Opacity")
                }
                .help("Blend the reference over the look-through view.")
                if store.referenceURL(reference).map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
                    Text("The reference image is missing. Choose it again.").shotsAttention()
                }
            }
            HStack {
                Button(shot.reference == nil ? "Choose image…" : "Replace image…") { importing = true }
                    .disabled(store.saveURL == nil)
                if shot.reference != nil {
                    Button("Remove reference") { store.run(.setReference(shot.id, nil)) }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            do { try store.importReference(from: result.get(), shotID: shot.id) } catch {
                store.onError?(error.localizedDescription)
            }
        }
    }
}
