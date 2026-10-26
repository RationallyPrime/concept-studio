import PrevisCore
import SwiftUI

/// Blockout Library.tsx:658–690: search name/category and toggle the armed asset.
/// The agreed first content set limits this browser to starter assets; placement belongs to Lane D.
struct ShotsAssetLibrary: View {
    @Bindable var store: ShotsStore
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Library").font(.headline)
            TextField("Find an asset", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(store.libraryAssets(matching: query)) { asset in
                        Button {
                            store.chooseAssetForPlacement(asset.id)
                        } label: {
                            HStack {
                                Text(asset.name)
                                Spacer()
                                if store.tool == .place(assetID: asset.id) {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                        .help("Choose \(asset.name), then click the ground in the scene view to place it.")
                        .accessibilityLabel("Place \(asset.name)")
                        .accessibilityValue(store.tool == .place(assetID: asset.id) ? "Selected" : "")
                    }
                }
            }
            .frame(minHeight: 60, idealHeight: 92, maxHeight: 150)
            if case let .place(assetID) = store.tool,
               let asset = store.catalog.assets.first(where: { $0.id == assetID }) {
                Text("Click the ground to place \(asset.name). Choose it again to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .disabled(store.isReadOnly || store.currentShot == nil)
        .accessibilityLabel("Asset library")
    }
}

extension ShotsStore {
    func libraryAssets(matching query: String) -> [AssetSpec] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return catalog.assets.filter { asset in
            catalog.starter.assets.contains(asset.id)
                && (query.isEmpty || asset.name.lowercased().contains(query)
                    || asset.category.lowercased().contains(query))
        }
    }

    func chooseAssetForPlacement(_ assetID: String) {
        guard !isReadOnly, currentScene != nil, currentShot != nil,
              libraryAssets(matching: "").contains(where: { $0.id == assetID }) else { return }
        tool = tool == .place(assetID: assetID) ? .select : .place(assetID: assetID)
    }
}
