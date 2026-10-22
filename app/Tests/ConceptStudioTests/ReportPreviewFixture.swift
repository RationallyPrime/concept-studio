import ConceptCore
@testable import ConceptStudio
import Foundation

/// Synthetic display values for layout checks; these are never recorded as measured training results.
@MainActor
func makeReportPreviewWorkspace(project: StudioProject, preferences: UserDefaults) throws -> GPUWorkspace {
    let workspace = makeWorkspace(GPUTransport(), preferences)
    workspace.chooseTrainingModel("black-forest-labs/FLUX.1-dev")
    workspace.projectFolder = project.directory
    let prompts = [
        ReportPrompt(
            id: "identity",
            trigger: "NORA7",
            category: .facialIdentity,
            kind: .concept,
            text: "NORA7 wearing a green sweater, reading in a quiet library.",
            heldOutAttributes: ["green sweater", "quiet library"]
        ),
        ReportPrompt(
            id: "bleed",
            trigger: "NORA7",
            category: .facialIdentity,
            kind: .bleed,
            text: "A person wearing a green sweater, reading in a quiet library.",
            heldOutAttributes: []
        ),
        ReportPrompt(
            id: "style",
            trigger: "STYLE7",
            category: .style,
            kind: .concept,
            text: "A ceramic teapot in the visual style of STYLE7.",
            heldOutAttributes: ["ceramic teapot"]
        ),
    ]
    let group = TrainingReportGroup(
        id: UUID().uuidString.lowercased(), name: "Synthetic report example", prompts: prompts, seeds: [42],
        settings: ReportRenderSettings(
            trainer: "aitoolkit", baseModel: workspace.baseModel, resolution: 512,
            inferenceSteps: 28, guidanceScale: 3.5, frames: 1, frameRate: 24,
            judgeModel: workspace.captionModel, judgeExtraBodyJSON: Data("{}".utf8)
        ), captionDigest: "synthetic", manualPrompts: false, frozenAt: Date(), createdAt: Date()
    )
    workspace.reportGroups = [group]
    workspace.selectedReportGroupID = group.id
    for index in 0 ..< 2 {
        let runID = "example-run-\(index + 1)", comparisonID = "example-render-\(index + 1)"
        let folder = project.directory.appendingPathComponent("results/" + comparisonID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (offset, name) in ["base.jpg", "lora.jpg"].enumerated() {
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.copyItem(at: project.images[index + offset].url, to: url)
            }
        }
        workspace.generations.append(GeneratedComparison(
            runID: comparisonID, sourceRunID: runID, checkpoint: "example.safetensors", trainer: "aitoolkit",
            volumeID: "example", startedAt: Date(), state: .saved, folder: folder.path,
            reportGroupID: group.id, reportPromptIDs: prompts.map(\.id), paramsJSON: Data("{}".utf8)
        ))
        let samples = prompts.map { prompt in
            ReportSample(
                comparisonID: comparisonID, promptID: prompt.id, seed: 42, basePath: "base.jpg", loraPath: "lora.jpg",
                identity: prompt.category.isPersonIdentity
                    ? ReportMetric(
                        base: 0.15,
                        lora: index == 0 && prompt.kind == .concept ? nil : 0.62,
                        note: index == 0 && prompt.kind == .concept ? "No usable face in this output."
                            : "Synthetic layout value; SFace cosine."
                    ) : nil,
                style: prompt.category == .style
                    ? ReportMetric(base: 0.41, lora: 0.78, note: "Synthetic layout value; VGG19 Gram-feature cosine.")
                    : nil,
                adherence: ReportMetric(
                    base: 0.6,
                    lora: 0.8,
                    note: "Synthetic layout value; prompt requirements match."
                )
            )
        }
        workspace.trainingReports.append(TrainingReport(
            runID: runID, groupID: group.id, state: .complete, samples: samples,
            completedPromptIDs: prompts.map(\.id), completedAt: Date()
        ))
    }
    return workspace
}
