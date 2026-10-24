import ConceptCore
import SwiftUI

struct H3AudioControls: View {
    @Bindable var workspace: GPUWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Train audio", isOn: Binding(
                get: { workspace.trainAudio },
                set: { workspace.trainAudio = $0; workspace.saveProjectRecord() }
            ))
            .disabled(workspace.isBusy || workspace.isTraining)
            Text(workspace.trainAudio
                ? "Learn sound as well as motion from this project's H3 clips. Turn this off to leave out "
                + "room noise, music or other sound you don't want learned."
                : "Learn the picture and motion only. Use N/A for both caption audio fields; "
                + "the trainer ignores clip audio. Still images are unchanged.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension StudioSession {
    var hasH3Clips: Bool {
        guard let project, let row = gpu.modelTable.nativeRecipeRow(.minimaxH3) else { return false }
        return project.job.profile == row.captions.videoProfile
            && project.images.contains { Sources.isVideo(Sources.suffix(of: $0.id)) }
    }

    static let h3AudioCaptionPolicy = """
    For H3 video clips in this project, audio training is off. Set overall_soundscape and
    non_diegetic_music to N/A. Describe the observed picture and motion normally. This choice
    does not change still-image captions.
    """
}
