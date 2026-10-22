import AppKit
import ConceptCore
@testable import ConceptStudio
import ImageIO
import SwiftUI
import Testing

extension PreviewRenderTests {
    func captureMappingStates(
        session: StudioSession, output: URL, filter: Set<String>, captures: inout [[String: String]]
    ) async throws {
        let root = StudioRootView(session: session)
        let image = try #require(session.project?.images.last)
        let trigger = try #require(session.project?.job.concepts.first?.trigger)
        let confirmed = session.project?.job.mapping(for: image.id)
        try session.project?.job.setMapping(nil, for: image.id)
        session.mappingProposals[image.id] = [trigger: "the person on the left in a green jacket"]
        session.selectedImageID = image.id
        try await capture("mapping-suggested", view: root, output: output, filter: filter, captures: &captures)
        session.mappingProposals = [:]
        session.receiveFaceRecognition(FaceRecognitionBatch(samples: [image.id: FaceRecognitionResult(faces: [
            RecognizedFace(
                box: CGRect(x: 0.3, y: 0.35, width: 0.25, height: 0.3),
                scores: [FaceIdentityScore(trigger: trigger, similarity: 0.36, band: .needsReview)]
            ),
        ])], referenceWarnings: [:]))
        try await capture("mapping-face-review", view: root, output: output, filter: filter, captures: &captures)
        for (name, score, band) in [
            ("mapping-face-match", Float(0.68), FaceMatchBand.match),
            ("mapping-face-no-match", Float(0.21), FaceMatchBand.noMatch),
        ] {
            session.receiveFaceRecognition(FaceRecognitionBatch(samples: [image.id: FaceRecognitionResult(faces: [
                RecognizedFace(
                    box: CGRect(x: 0.3, y: 0.35, width: 0.25, height: 0.3),
                    scores: [FaceIdentityScore(trigger: trigger, similarity: score, band: band)]
                ),
            ])], referenceWarnings: [:]))
            try await capture(name, view: root, output: output, filter: filter, captures: &captures)
        }
        try await captureReferenceWarning(session: session, output: output, filter: filter, captures: &captures)
        session.invalidateFaceRecognition()
        try session.project?.job.setMapping(confirmed, for: image.id)
        session.mappingProposals = [:]
        let job = try #require(session.project?.job)
        session.project?.job.concepts = try [Concept(trigger: "DEMO_STYLE", targetConcept: .style)]
        try await capture("mapping-style", view: root, output: output, filter: filter, captures: &captures)
        session.project?.job = job
    }

    private func captureReferenceWarning(
        session: StudioSession, output: URL, filter: Set<String>, captures: inout [[String: String]]
    ) async throws {
        guard filter.isEmpty || filter.contains("mapping-face-reference-warning"),
              let reference = session.personReferences.values.first else { return }
        let original = try Data(contentsOf: reference)
        defer { try? original.write(to: reference); session.inspectReferenceFaces() }
        let source = try #require(CGImageSourceCreateWithData(original as CFData, nil))
        let small = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 200,
        ] as CFDictionary))
        try MediaEditor.png(small).write(to: reference)
        session.inspectReferenceFaces()
        await session.referenceWarningTask?.value
        #expect(session.faceReferenceWarnings.values.contains { !$0.isEmpty })
        try await capture(
            "mapping-face-reference-warning", view: StudioRootView(session: session),
            output: output, filter: filter, captures: &captures
        )
    }

    func captureFollowupScreens(
        session: StudioSession, output: URL, filter: Set<String>, captures: inout [[String: String]]
    ) async throws {
        let workspace = GPUWorkspace(demoMode: true, preferences: session.preferences)
        workspace.chooseTrainingModel("black-forest-labs/FLUX.1-dev")
        let unsupported = try #require(ModelTable.shared.models.first { !$0.trainingTransforms.lossMask })
        if let image = session.project?.images.first(where: { $0.id == "studio.jpg" }) {
            let previousWorkspace = session.gpu
            session.gpu = workspace
            defer { session.gpu = previousWorkspace }
            try await capture(
                "photo-editor", view: MediaEditorView(session: session, media: image),
                output: output, filter: filter, captures: &captures,
                renderSizes: [
                    ("minimum", CGSize(width: 720, height: 660)),
                    ("default", CGSize(width: 980, height: 820)),
                ], settleFor: .seconds(1)
            )
            try await capture(
                "photo-adjustments", view: PhotoAdjustmentControls(adjustments: .constant(PhotoAdjustments(
                    autoEnhance: true, exposure: 0.5, highlights: 0.7, shadows: 0.3, temperature: 5800,
                    straightenDegrees: 2.5
                ))).padding(24), output: output, filter: filter, captures: &captures,
                renderSizes: [
                    ("minimum", CGSize(width: 720, height: 660)),
                    ("default", CGSize(width: 980, height: 820)),
                ]
            )
            try await capture(
                "loss-mask", view: TrainingLossMaskEditor(session: session, media: image),
                output: output, filter: filter, captures: &captures,
                renderSizes: [
                    ("minimum", CGSize(width: 720, height: 700)),
                    ("default", CGSize(width: 980, height: 820)),
                ], settleFor: .seconds(1)
            )
            workspace.chooseTrainingModel(unsupported.modelRef)
            try await capture(
                "loss-mask-unsupported", view: TrainingLossMaskEditor(session: session, media: image),
                output: output, filter: filter, captures: &captures,
                renderSizes: [
                    ("minimum", CGSize(width: 720, height: 700)),
                    ("default", CGSize(width: 980, height: 820)),
                ], settleFor: .seconds(1)
            )
        }
        for (name, model, style, mode) in [
            ("augmentation-person", "black-forest-labs/FLUX.1-dev", false, TrainingAugmentation.none),
            ("augmentation-style", "black-forest-labs/FLUX.1-dev", true, TrainingAugmentation.square),
            ("augmentation-unsupported", unsupported.modelRef, false, TrainingAugmentation.none),
        ] {
            workspace.chooseTrainingModel(model)
            workspace.squareAugmentationAllowed = style
            workspace.trainingAugmentation = mode
            try await capture(
                name, view: VStack(alignment: .leading, spacing: 16) {
                    Text("Training-time transforms").font(.title2.bold())
                    TrainingAugmentationControls(workspace: workspace)
                }.padding(24).frame(maxHeight: .infinity, alignment: .top),
                output: output, filter: filter, captures: &captures,
                renderSizes: [
                    ("minimum", CGSize(width: 720, height: 600)),
                    ("default", CGSize(width: 980, height: 820)),
                ]
            )
        }
        try await capturePhotoOutliers(session: session, output: output, filter: filter, captures: &captures)
        try await captureReportScreens(session: session, output: output, filter: filter, captures: &captures)
    }

    private func capturePhotoOutliers(
        session: StudioSession, output: URL, filter: Set<String>, captures: inout [[String: String]]
    ) async throws {
        guard filter.isEmpty || filter.contains("photo-outliers") else { return }
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let source = try #require(project.images.first { $0.id == "garden.jpg" })
        let original = try Data(contentsOf: source.url)
        let dark = try PhotoEditing.render(
            MediaEditor.orientedImage(original), adjustments: PhotoAdjustments(exposure: -2.5)
        )
        let darkBytes = try #require(NSBitmapImageRep(cgImage: dark).representation(using: .jpeg, properties: [:]))
        for (index, image) in project.images.enumerated() {
            try (index == 0 ? darkBytes : original).write(to: image.url)
        }
        PhotoThumbnails.removeAll()
        await prewarmThumbnails(project.images.map(\.url))
        let fixture = makeTestSession()
        fixture.demoMode = true
        fixture.project = project
        defer { fixture.stopImageAnalysis() }
        try await capture(
            "photo-outliers", view: PhotoOutliersSheet(session: fixture),
            output: output, filter: filter, captures: &captures,
            renderSizes: [
                ("minimum", CGSize(width: 720, height: 650)),
                ("default", CGSize(width: 980, height: 820)),
            ], settleFor: .seconds(1)
        )
    }

    private func captureReportScreens(
        session: StudioSession, output: URL, filter: Set<String>, captures: inout [[String: String]]
    ) async throws {
        guard filter.isEmpty || filter.contains("report-plan") || filter.contains("report-results"),
              let project = session.project else { return }
        let workspace = try makeReportPreviewWorkspace(project: project, preferences: session.preferences)
        try await capture(
            "report-plan", view: ScrollView { ReportPlanView(workspace: workspace).padding(24) },
            output: output, filter: filter, captures: &captures
        )
        try await capture(
            "report-results", view: ScrollView { TrainingReportResultsView(workspace: workspace).padding(24) },
            output: output, filter: filter, captures: &captures
        )
    }
}
