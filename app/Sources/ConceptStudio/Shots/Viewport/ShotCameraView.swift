import PrevisCore
import SwiftUI

/// Look-through view for the active shot camera, letterboxed to the shot canvas (CONTRACTS section 7).
/// D0 provides the placeholder surface wired to `ShotsStore`.
struct ShotCameraView: View {
    let store: ShotsStore

    private var canvas: ShotCanvas {
        store.currentShot?.canvas ?? .portrait
    }

    var body: some View {
        ZStack {
            InstantPrint.frame
            VStack(spacing: 8) {
                Image(systemName: "video")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(InstantPrint.frameText)
                Text("Shot camera")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(InstantPrint.frameText)
                Text(captionText)
                    .font(.system(size: 12))
                    .foregroundStyle(InstantPrint.frameMuted)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(CGFloat(canvas.aspect), contentMode: .fit)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(InstantPrint.frameRule, lineWidth: 1)
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shot camera preview. \(captionText)")
    }

    private var captionText: String {
        guard let shot = store.currentShot else {
            return "No active shot · \(canvas.width) × \(canvas.height)"
        }
        return "Shot \(shot.name) · \(canvas.width) × \(canvas.height) · Frame \(store.playhead)"
    }
}
