import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("SFace clip agreement")
struct SFaceClipTests {
    private func frame(_ values: [String: Float], reason: String? = nil) -> FaceRecognitionResult {
        let policy = FaceRecognitionPolicy()
        return FaceRecognitionResult(faces: [RecognizedFace(
            box: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.5),
            scores: values.map { FaceIdentityScore(
                trigger: $0.key,
                similarity: $0.value,
                band: policy.band(similarity: $0.value)
            ) },
            reviewReason: reason
        )])
    }

    @Test func consistentFramesKeepTheWeakestMatchAndStrongestNegative() throws {
        let frames = [
            frame(["NORA7": 0.9, "IVAN9": 0.1]), frame(["NORA7": 0.5, "IVAN9": 0.2]),
            frame(["NORA7": 0.8, "IVAN9": 0.3]), frame(["NORA7": 0.7, "IVAN9": 0.15]),
            frame(["NORA7": 0.6, "IVAN9": 0.25]),
        ]
        let result = FaceRecognitionResult.clip(frames)
        #expect(result.mappingBand == .match)
        #expect(result.singleMatch(for: "NORA7"))
        #expect(result.faces.first?.box == frames.first?.faces.first?.box)
        let scores = try #require(result.faces.first?.scores)
        #expect(scores.first { $0.trigger == "NORA7" }?.similarity == 0.5)
        #expect(scores.first { $0.trigger == "IVAN9" }?.similarity == 0.3)
    }

    @Test func consistentNegativeAndIntermediateEvidenceKeepTheirBands() {
        let negative = FaceRecognitionResult.clip([
            frame(["NORA7": 0.1, "IVAN9": 0.2]), frame(["NORA7": 0.3, "IVAN9": 0.1]),
        ])
        #expect(negative.mappingBand == .noMatch)
        #expect(negative.faces.first?.scores.first?.similarity == 0.3)
        let uncertain = FaceRecognitionResult.clip([frame(["NORA7": 0.34]), frame(["NORA7": 0.38])])
        #expect(uncertain.mappingBand == .needsReview)
        #expect(uncertain.faces.first?.scores.first?.similarity == 0.38)
        #expect(!uncertain.singleMatch(for: "NORA7"))
    }

    @Test(arguments: ["identity", "band", "secondary-band", "missing-score", "nonfinite"])
    func anyIdentityOrBandDisagreementRequiresReview(_ scenario: String) {
        let first = frame(["NORA7": 0.8, "IVAN9": 0.1])
        let other: FaceRecognitionResult = switch scenario {
        case "identity": frame(["NORA7": 0.1, "IVAN9": 0.8])
        case "band": frame(["NORA7": 0.35, "IVAN9": 0.1])
        case "secondary-band": frame(["NORA7": 0.8, "IVAN9": 0.35])
        case "missing-score": frame(["NORA7": 0.8])
        default: frame(["NORA7": .nan, "IVAN9": 0.1])
        }
        let result = FaceRecognitionResult.clip([first, other, first])
        #expect(result.mappingBand == .needsReview)
        #expect(result.reviewReason != nil)
        #expect(!result.singleMatch(for: "NORA7"))
    }

    @Test(arguments: ["missing", "tilted", "landmarks", "multiple", "ambiguous", "empty"])
    func missingOrUnusableFacesNeverBecomeAnAutomaticMatch(_ scenario: String) {
        let good = frame(["NORA7": 0.8])
        let poor: FaceRecognitionResult = switch scenario {
        case "missing": FaceRecognitionResult(reviewReason: "No face detected")
        case "tilted": frame(["NORA7": 0.8], reason: "Face tilted more than 35°")
        case "landmarks": frame(["NORA7": 0.8], reason: "Face landmarks could not be located")
        case "multiple": FaceRecognitionResult(faces: good.faces + good.faces)
        case "ambiguous": frame(["NORA7": 0.8, "IVAN9": 0.8], reason: "More than one reference matches this face")
        default: FaceRecognitionResult()
        }
        let result = FaceRecognitionResult.clip([good, poor, good])
        #expect(result.mappingBand == .needsReview)
        #expect(result.reviewReason != nil)
        #expect(!result.singleMatch(for: "NORA7"))
        #expect(FaceRecognitionResult.clip([poor, poor]).mappingBand == .needsReview)
        #expect(FaceRecognitionResult.clip([]).mappingBand == .needsReview)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONCEPTSTUDIO_SFACE_ACCEPTANCE"] == "1"))
    func nativeModelMatchesPanZoomAndReviewsOneMissingFrame() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let reference = try #require(project.images.first { $0.id == "studio.jpg" }).url
        let image = try SFaceRecognizer.image(reference)
        let clear = project.directory.appendingPathComponent("synthetic-pan-zoom.mp4")
        let mixed = project.directory.appendingPathComponent("synthetic-missing-face.mp4")
        try await SFaceClipFixture.write(image, to: clear)
        try await SFaceClipFixture.write(image, to: mixed, blankMiddle: true)
        let sampled = try await MediaEditor.frames(url: mixed)
        #expect(sampled.count == 5)
        #expect(sampled.first?.seconds == 0)
        #expect(zip(sampled, sampled.dropFirst()).allSatisfy { $0.seconds < $1.seconds })
        let decoded = try sampled.enumerated().map { index, frame in
            let url = project.directory.appendingPathComponent("sample-\(index).png")
            try MediaEditor.png(frame.image).write(to: url)
            return url
        }
        let unreadable = project.directory.appendingPathComponent("unreadable.mp4")
        try Data("not a video".utf8).write(to: unreadable)
        let recognizer = SFaceRecognizer()
        let batch = try await recognizer.recognize(
            images: [reference, clear, mixed, unreadable] + decoded, references: ["NORA7": reference]
        )
        let clearResult = try #require(batch.samples[clear.lastPathComponent])
        let mixedResult = try #require(batch.samples[mixed.lastPathComponent])
        #expect(clearResult.singleMatch(for: "NORA7"))
        #expect(batch.samples[reference.lastPathComponent]?.singleMatch(for: "NORA7") == true)
        #expect(mixedResult.mappingBand == .needsReview)
        #expect(mixedResult.reviewReason != nil)
        #expect(batch.samples[unreadable.lastPathComponent]?.mappingBand == .needsReview)
        let sampleResults = try decoded.map { try #require(batch.samples[$0.lastPathComponent]) }
        #expect(sampleResults.filter { $0.singleMatch(for: "NORA7") }.count == 4)
        #expect(sampleResults.filter(\.faces.isEmpty).count == 1)
        print("SFace native clip acceptance: times=\(sampled.map(\.seconds)); "
            + "panZoom=\(clearResult.summary); mixed=\(mixedResult.summary); sampledFaces=4 match/1 missing")

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await recognizer.recognize(images: [clear], references: ["NORA7": reference])
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    }
}
