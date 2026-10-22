import SwiftUI

enum TrainingAugmentation: String, CaseIterable {
    case none, horizontal, square

    var title: String {
        switch self {
        case .none: "Off"
        case .horizontal: "Horizontal flips"
        case .square: "All eight square symmetries"
        }
    }
}

extension GPUWorkspace {
    var effectiveAugmentation: TrainingAugmentation {
        let support = effectiveModelRow.trainingTransforms
        switch trainingAugmentation {
        case .none: return .none
        case .horizontal: return support.horizontalFlip ? .horizontal : .none
        case .square:
            return support
                .squareSymmetry && squareAugmentationAllowed && !trainingDatasetContainsVideo ? .square : .none
        }
    }
}

struct TrainingAugmentationControls: View {
    @Bindable var workspace: GPUWorkspace

    var body: some View {
        let support = workspace.effectiveModelRow.trainingTransforms
        if support.horizontalFlip {
            Picker("Training-time augmentation", selection: $workspace.trainingAugmentation) {
                Text(TrainingAugmentation.none.title).tag(TrainingAugmentation.none)
                Text(TrainingAugmentation.horizontal.title).tag(TrainingAugmentation.horizontal)
                if support.squareSymmetry, workspace.squareAugmentationAllowed,
                   !workspace.trainingDatasetContainsVideo {
                    Text(TrainingAugmentation.square.title).tag(TrainingAugmentation.square)
                }
            }
            Text("Off by default. Captions that name left or right are never flipped. "
                + "Transforms run during training without creating media copies.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
            if workspace.trainingAugmentation != workspace.effectiveAugmentation {
                Text("The saved augmentation choice is unavailable for these inputs and will not be applied.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
        }
        LabeledContent("Loss masks", value: support.lossMask ? "Supported" : "Unavailable")
        Text(support.note).font(.callout).foregroundStyle(StudioStyle.supportingText)
    }
}
