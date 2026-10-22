import Foundation

enum FaceMatchBand: String, Codable, Sendable {
    case match, needsReview, noMatch

    var title: String {
        switch self {
        case .match: "Match"
        case .needsReview: "Needs review"
        case .noMatch: "No match"
        }
    }
}

/// The measured starting points live together so a new calibration changes one policy.
struct FaceRecognitionPolicy: Sendable {
    var matchThreshold: Float = 0.39
    var reviewThreshold: Float = 0.33
    var maximumRollDegrees: Double = 35
    var minimumEyeSpacingRatio: Double = 0.2
    var minimumReferencePixels: Double = 100
    var minimumReferenceQuality: Float = 0.3

    func band(similarity: Float, reviewReason: String? = nil) -> FaceMatchBand {
        guard reviewReason == nil, similarity.isFinite else { return .needsReview }
        if similarity > matchThreshold { return .match }
        return similarity > reviewThreshold ? .needsReview : .noMatch
    }
}

struct FaceIdentityScore: Equatable, Sendable {
    var trigger: String
    var similarity: Float
    var band: FaceMatchBand
}

struct RecognizedFace: Equatable, Sendable {
    /// Vision coordinates: normalized, origin at the bottom left.
    var box: CGRect
    var scores: [FaceIdentityScore]
    var reviewReason: String?

    var match: FaceIdentityScore? {
        let matches = scores.filter { $0.band == .match }
        return reviewReason == nil && matches.count == 1 ? matches.first : nil
    }
}

struct FaceRecognitionResult: Equatable, Sendable {
    var faces: [RecognizedFace] = []
    var reviewReason: String?

    func singleMatch(for trigger: String) -> Bool {
        reviewReason == nil && faces.count == 1 && faces.first?.match?.trigger == trigger
    }

    var summary: String {
        if let reviewReason { return "Needs review · \(reviewReason)" }
        return faces.enumerated().map { index, face in
            if let reason = face.reviewReason { return "Face \(index + 1): Needs review · \(reason)" }
            let scores = face.scores.map {
                "\($0.trigger): \($0.band.title) (\(String(format: "%.3f", $0.similarity)))"
            }.joined(separator: ", ")
            return "Face \(index + 1): \(scores)"
        }.joined(separator: "\n")
    }
}

struct FaceRecognitionBatch: Sendable {
    var samples: [String: FaceRecognitionResult]
    var referenceWarnings: [String: [String]]
}

/// An orientation-preserving least-squares similarity transform, equivalent to the
/// five-point Umeyama alignment used in the measured SFace experiment.
struct FaceAlignment: Sendable {
    static let template = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366), CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    var a: Double
    var b: Double
    var x: Double
    var y: Double

    init(points: [CGPoint], target: [CGPoint] = Self.template) throws {
        guard points.count == 5, target.count == 5,
              (points + target).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw StudioError.message("The face landmarks cannot be aligned. Review this photo manually.")
        }
        let sourceMean = Self.mean(points), targetMean = Self.mean(target)
        var denominator = 0.0, real = 0.0, imaginary = 0.0
        for (source, destination) in zip(points, target) {
            let sx = source.x - sourceMean.x, sy = source.y - sourceMean.y
            let dx = destination.x - targetMean.x, dy = destination.y - targetMean.y
            denominator += sx * sx + sy * sy
            real += sx * dx + sy * dy
            imaginary += sx * dy - sy * dx
        }
        guard denominator > 0.0001 else {
            throw StudioError.message("The face landmarks overlap. Review this photo manually.")
        }
        a = real / denominator
        b = imaginary / denominator
        x = targetMean.x - a * sourceMean.x + b * sourceMean.y
        y = targetMean.y - b * sourceMean.x - a * sourceMean.y
        guard a * a + b * b > 0.000001 else {
            throw StudioError.message("The face landmarks have collapsed. Review this photo manually.")
        }
    }

    func sourcePoint(x destinationX: Double, y destinationY: Double) -> CGPoint {
        let dx = destinationX - x, dy = destinationY - y, determinant = a * a + b * b
        return CGPoint(x: (a * dx + b * dy) / determinant, y: (-b * dx + a * dy) / determinant)
    }

    static func mean(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        return CGPoint(
            x: points.reduce(0) { $0 + $1.x } / Double(points.count),
            y: points.reduce(0) { $0 + $1.y } / Double(points.count)
        )
    }
}
