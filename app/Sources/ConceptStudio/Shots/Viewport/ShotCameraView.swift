import PrevisCore
import SwiftUI

/// Look-through view for the active shot camera, letterboxed to the shot canvas (CONTRACTS section 7).
/// D0 provides the placeholder surface wired to `ShotsStore`.
struct ShotCameraView: View {
    let store: ShotsStore
    var externalSession: ViewportLiveSession?
    var onToggleLookThrough: (() -> Void)?
    var claimFocusOnAppear = false
    var onClaimedFocus: (() -> Void)?

    @State private var ownedSession = ViewportLiveSession()

    var session: ViewportLiveSession {
        externalSession ?? ownedSession
    }

    private var canvas: ShotCanvas {
        store.currentShot?.canvas ?? .portrait
    }

    var body: some View {
        GeometryReader { geometry in
            let currentSize = PixelSize(
                width: max(Int(geometry.size.width.rounded()), 1),
                height: max(Int(geometry.size.height.rounded()), 1)
            )
            ZStack {
                InstantPrint.ground
                VStack(spacing: 8) {
                    Image(systemName: "video")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Shot camera")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(captionText)
                        .font(.system(size: 12))
                        .foregroundStyle(StudioStyle.supportingText)
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(CGFloat(canvas.aspect), contentMode: .fit)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.20), lineWidth: 1)
                }
                .padding(8)

                ViewportKeyCaptureOverlay(
                    session: session,
                    claimFocusOnAppear: claimFocusOnAppear,
                    onClaimedFocus: onClaimedFocus,
                    onKeyDown: { characters, keyCode, modifiers in
                        session.viewportSize = currentSize
                        return ViewportKeyboard.handleKeyDown(
                            charactersIgnoringModifiers: characters,
                            keyCode: keyCode,
                            modifiers: modifiers,
                            in: store,
                            session: session,
                            onToggleLookThrough: onToggleLookThrough
                        )
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
        }
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
