import AppKit
import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Reversible photo edits and training loss masks")
struct PhotoEditingTests {
    @Test @MainActor func editsReopenFromTheOriginalResetCaptionAndUndoRestoresBytes() async throws {
        let session = makeTestSession()
        session.demoMode = true
        session.project = try await makeDemoProject()
        let originalProject = try #require(session.project)
        defer { session.stopImageAnalysis(); try? FileManager.default.removeItem(at: originalProject.directory) }
        let photo = try #require(originalProject.images.first { $0.id == "garden.jpg" })
        let bytes = try Data(contentsOf: photo.url)
        let originalSize = try MediaEditor.orientedImage(bytes)
        session.projectState.notSure[photo.id] = "Review subject assignment"
        var captionedProject = originalProject
        try await captionedProject.saveCaption(id: photo.id, text: "NORA7 protected caption.", final: true)
        session.project = captionedProject
        session.setCaptionDraft(CaptionDraft(text: "Unsaved text", isFinal: true), for: photo.id)
        let first = PhotoAdjustments(exposure: 0.5, crop: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        session.approvePhotoEdits(id: photo.id, adjustments: first)
        await session.task?.value
        #expect(session.errorMessage == nil)
        let editedID = try #require(session.selectedImageID)
        var reopened = try await StudioProject.open(at: originalProject.directory)
        let edited = try #require(reopened.images.first { $0.id == editedID })
        #expect(edited.caption.isEmpty && !edited.isFinal)
        #expect(reopened.job.mapping(for: editedID) == nil)
        #expect(session.captionDrafts[photo.id] == nil)
        #expect(session.projectState.notSure[editedID] == "Review subject assignment")
        #expect(try Data(contentsOf: reopened.photoEditSource(for: edited)) == bytes)
        #expect(reopened.mediaState.selections[editedID]?.photoEdit?.adjustments == first)
        // The second recipe covers the complete original, not the already cropped output.
        session.approvePhotoEdits(id: editedID, adjustments: PhotoAdjustments(quarterTurns: 1))
        await session.task?.value
        #expect(session.errorMessage == nil)
        reopened = try await StudioProject.open(at: originalProject.directory)
        let rotated = try #require(reopened.images.first { $0.id == editedID })
        let rotatedImage = try MediaEditor.orientedImage(Data(contentsOf: rotated.url))
        #expect(rotatedImage.width == originalSize.height && rotatedImage.height == originalSize.width)
        session.undoMediaCuration()
        #expect(session.project?.mediaState.selections[editedID]?.photoEdit?.adjustments == first)
        session.undoMediaCuration()
        #expect(try Data(contentsOf: photo.url) == bytes)
        #expect(session.project?.images.first { $0.id == photo.id }?.caption == "NORA7 protected caption.")
    }

    @Test func outlierCorrectionTouchesOnlyTheSpecificColourOrExposureOutlier() {
        let ordinary = PhotoStatistics(exposure: -1, redBalance: 0, blueBalance: 0)
        var values = Dictionary(uniqueKeysWithValues: (0 ..< 8).map { ("normal-\($0)", ordinary) })
        values["dark"] = PhotoStatistics(exposure: -3, redBalance: 0, blueBalance: 0)
        values["red"] = PhotoStatistics(exposure: -1, redBalance: 0.8, blueBalance: 0)
        let suggestions = PhotoOutliers.suggestions(values)
        #expect(Set(suggestions.map(\.id)) == ["dark", "red"])
        #expect(suggestions.first { $0.id == "dark" }?.exposure == 1.5)
        #expect(suggestions.first { $0.id == "dark" }?.redGain == 1)
        #expect(suggestions.first { $0.id == "red" }?.exposure == 0)
        #expect(suggestions.first { $0.id == "red" }?.blueGain == 1)
        #expect(PhotoOutliers.suggestions(["a": ordinary, "b": ordinary, "c": ordinary]).isEmpty)
    }

    @Test func lossMaskCoordinatesAndSourceIdentitySurvivePngEncoding() throws {
        let directory = temporaryTestDirectory("loss-mask-pixels")
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = try StudioProject.create(at: directory)
        let bytes = try MediaEditor.png(MediaFixtures.image(width: 100, height: 80))
        let id = try project.importData(bytes, name: "target.png")
        let target = project.imagesDirectory.appendingPathComponent(id)
        try TrainingLossMasks.save(
            rectangles: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5)], imageURL: target, project: project
        )
        let maskURL = try #require(try TrainingLossMasks.validURL(for: target, in: directory))
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: maskURL)))
        #expect(bitmap.pixelsWide == 100 && bitmap.pixelsHigh == 80)
        #expect(try #require(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceGray)).whiteComponent < 0.01)
        #expect(try #require(bitmap.colorAt(x: 90, y: 70)?.usingColorSpace(.deviceGray)).whiteComponent > 0.99)
        #expect(try #require(bitmap.colorAt(x: 10, y: 70)?.usingColorSpace(.deviceGray)).whiteComponent > 0.99)
        try AtomicFile.write(MediaEditor.png(MediaFixtures.image(width: 100, height: 90)), to: target)
        #expect(try TrainingLossMasks.validURL(for: target, in: directory) == nil)
        try AtomicFile.write(bytes, to: target)
        #expect(try TrainingLossMasks.validURL(for: target, in: directory) == maskURL)
    }

    @Test func cropDragKeepsHandlesAndTranslationInsideTheImage() {
        let start = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
        #expect(InteractivePhotoCrop.dragged(start, dx: 3, dy: -3, corner: nil) ==
            CGRect(x: 0.5, y: 0, width: 0.5, height: 0.6))
        let collapsed = InteractivePhotoCrop.dragged(start, dx: 2, dy: 2, corner: 0)
        #expect(abs(collapsed.width - 0.02) < 0.00001 && abs(collapsed.height - 0.02) < 0.00001)
        let expanded = InteractivePhotoCrop.dragged(start, dx: 3, dy: 3, corner: 3)
        #expect(expanded.maxX == 1 && expanded.maxY == 1)
    }
}
