import ConceptCore
@testable import ConceptStudio
import CoreGraphics
import Foundation
import Testing

@Suite("Photo editor review regressions")
struct PhotoEditingReviewTests {
    @Test func narrowCropAndMaskHandlesAlwaysHaveAValidSliderRange() {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        let narrowed = InteractivePhotoCrop.dragged(whole, dx: 1, dy: 1, corner: 0)
        let width = InteractivePhotoCrop.sizeRange(after: narrowed.minX)
        let height = InteractivePhotoCrop.sizeRange(after: narrowed.minY)
        #expect(width.lowerBound <= width.upperBound)
        #expect(height.lowerBound <= height.upperBound)
        #expect(abs(width.upperBound - narrowed.width) < 0.000001)
        #expect(abs(height.upperBound - narrowed.height) < 0.000001)
        #expect(InteractivePhotoCrop.sizeRange(after: 0.98.nextUp).upperBound >= 0.02)
    }

    @MainActor @Test func photoEditRestoresTheActualSourceNameAfterAnEarlierCrop() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let source = try #require(project.images.first { $0.id == "garden.jpg" })
        let cropped = try MediaEditor.cropped(
            Data(contentsOf: source.url),
            rectangle: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        )
        try project.approveTarget(
            id: source.id, data: cropped, name: "garden.png",
            selection: MediaSelection(originalName: source.id, crop: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        )
        let session = makeTestSession()
        session.project = project
        defer { session.stopImageAnalysis() }
        session.approvePhotoEdits(id: "garden.png", adjustments: PhotoAdjustments(exposure: 0.5))
        await session.task?.value
        #expect(session.errorMessage == nil)
        session.restoreOriginalPhoto(id: "garden.png")
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.selectedImageID == "garden.png")
        #expect(try Data(contentsOf: project.imagesDirectory.appendingPathComponent("garden.png")) == cropped)
        #expect(!FileManager.default
            .fileExists(atPath: project.imagesDirectory.appendingPathComponent("garden.jpg").path))
    }

    @Test func faceTensorKeepsTheImagesTopAndBottomOrientation() throws {
        var pixels = [UInt8](repeating: 0, count: 112 * 112 * 4)
        for y in 0 ..< 112 {
            for x in 0 ..< 112 {
                let index = (y * 112 + x) * 4
                pixels[index + (y < 56 ? 0 : 2)] = 255
                pixels[index + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: 112, height: 112, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 448,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let tensor = try SFaceRecognizer.alignedRGB(image: image, points: FaceAlignment.template)
        #expect(tensor[10 * 112 + 10] > 254)
        #expect(tensor[2 * 112 * 112 + 100 * 112 + 10] > 254)
    }
}
