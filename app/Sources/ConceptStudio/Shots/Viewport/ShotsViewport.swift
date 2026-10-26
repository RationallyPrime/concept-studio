import PrevisCore
import SwiftUI

/// Free editor camera viewport for 3D shot blocking (CONTRACTS section 7).
/// D0 provides the placeholder surface wired to `ShotsStore` and `EditorCamera`.
struct ShotsViewport: View {
    let store: ShotsStore
    @State private var editorCamera = EditorCamera.defaultView

    init(store: ShotsStore) {
        self.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("3D blocking viewport")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if store.isReadOnly {
                    Text("Read-only")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
            }

            Text(summaryText)
                .font(.system(size: 13))
                .foregroundStyle(StudioStyle.supportingText)
                .monospacedDigit()

            Text(cameraSummaryText)
                .font(.system(size: 12))
                .foregroundStyle(StudioStyle.supportingText)
                .monospacedDigit()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(InstantPrint.ground, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var summaryText: String {
        guard let scene = store.currentScene, let shot = store.currentShot else {
            return "No active shot selected."
        }
        let entityCount = store.frame?.entities.count ?? scene.entities.count
        let frameSummary = "Frame \(store.playhead) of \(shot.frameCount)"
        return "\(scene.name) · Shot \(shot.name) · \(frameSummary) · \(entityCount) entities"
    }

    private var cameraSummaryText: String {
        let distance = String(format: "%.1f", editorCamera.distance)
        return "Editor camera · \(distance) m from target"
    }

    private var accessibilityDescription: String {
        if store.isReadOnly {
            return "3D blocking viewport, read-only. \(summaryText)"
        }
        return "3D blocking viewport. \(summaryText)"
    }
}
