import AppKit
@testable import ConceptStudio
import Foundation
import Testing

@Suite("SFace recognition and alignment")
struct FaceRecognitionTests {
    @Test func calibrationHasThreeBandsAndQualityGates() {
        let policy = FaceRecognitionPolicy()
        #expect(policy.band(similarity: 0.4) == .match)
        #expect(policy.band(similarity: 0.39) == .needsReview)
        #expect(policy.band(similarity: 0.34) == .needsReview)
        #expect(policy.band(similarity: 0.33) == .noMatch)
        #expect(policy.band(similarity: .nan) == .needsReview)
        #expect(policy.band(similarity: 0.99, reviewReason: "Tilted") == .needsReview)
    }

    @Test func fivePointFitRecoversRotationScaleAndTranslation() throws {
        let angle = Double.pi / 7, scale = 3.2
        let source = FaceAlignment.template.map { point in
            CGPoint(
                x: scale * (cos(angle) * point.x - sin(angle) * point.y) + 40,
                y: scale * (sin(angle) * point.x + cos(angle) * point.y) + 70
            )
        }
        let alignment = try FaceAlignment(points: source)
        for (expected, destination) in zip(source, FaceAlignment.template) {
            let actual = alignment.sourcePoint(x: destination.x, y: destination.y)
            #expect(abs(actual.x - expected.x) < 0.00001)
            #expect(abs(actual.y - expected.y) < 0.00001)
        }
        #expect(throws: (any Error).self) {
            try FaceAlignment(points: Array(repeating: .zero, count: 5))
        }
    }

    @Test func pixelsUseRGBZeroTo255WithoutArcFaceNormalization() throws {
        let pixels = Data(Array(repeating: [UInt8(255), 128, 0, 255], count: 112 * 112).flatMap(\.self))
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(
            width: 112, height: 112, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 112 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let tensor = try SFaceRecognizer.alignedRGB(
            image: image, points: FaceAlignment.template
        )
        #expect(tensor.count == 3 * 112 * 112)
        let pixel = 56 * 112 + 56
        #expect(tensor[pixel] == 255)
        #expect(abs(tensor[112 * 112 + pixel] - 128) <= 1)
        #expect(tensor[2 * 112 * 112 + pixel] == 0)
    }

    @Test func bulkRequiresOneFaceOneMatchAndNoReviewGate() {
        let match = FaceIdentityScore(trigger: "NORA7", similarity: 0.7, band: .match)
        let face = RecognizedFace(box: .zero, scores: [match])
        #expect(FaceRecognitionResult(faces: [face]).singleMatch(for: "NORA7"))
        #expect(!FaceRecognitionResult(faces: [face, face]).singleMatch(for: "NORA7"))
        #expect(!FaceRecognitionResult(reviewReason: "No face detected").singleMatch(for: "NORA7"))
        let held = RecognizedFace(box: .zero, scores: [match], reviewReason: "Tilted")
        #expect(!FaceRecognitionResult(faces: [held]).singleMatch(for: "NORA7"))
        let ambiguous = RecognizedFace(box: .zero, scores: [
            match, FaceIdentityScore(trigger: "IVAN9", similarity: 0.6, band: .match),
        ])
        #expect(!FaceRecognitionResult(faces: [ambiguous]).singleMatch(for: "NORA7"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONCEPTSTUDIO_SFACE_ACCEPTANCE"] == "1"))
    func realModelRecognizesTheSameDemoFace() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let source = try #require(project.images.first { $0.id == "studio.jpg" })
        let result = try await SFaceRecognizer().recognize(
            images: [source.url], references: ["NORA7": source.url]
        )
        let sample = try #require(result.samples[source.id])
        #expect(sample.singleMatch(for: "NORA7"))
        #expect(try #require(sample.faces.first?.scores.first?.similarity) > 0.99)
    }
}
