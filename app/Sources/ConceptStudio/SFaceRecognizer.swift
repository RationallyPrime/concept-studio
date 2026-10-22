import ConceptCore
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import OnnxRuntimeBindings
import Vision

/// Native, on-device identity inference. Only the public model file is downloaded;
/// photos and embeddings stay on this Mac.
actor SFaceRecognizer {
    static let modelName = "SFace 2021dec"
    static let modelRevision = "3d7082438a6e4551e840c9b2bb60b71e8da4b524"
    static let modelSHA256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
    static let modelBytes = 38_696_353
    static let modelPage = URL(string: "https://huggingface.co/opencv/face_recognition_sface")!
    static let licenseURL = modelPage.appendingPathComponent("blob/\(modelRevision)/LICENSE")
    static let modelURL = modelPage.appendingPathComponent(
        "resolve/\(modelRevision)/face_recognition_sface_2021dec.onnx"
    )

    private let policy: FaceRecognitionPolicy
    private var environment: ORTEnv?
    private var session: ORTSession?

    init(policy: FaceRecognitionPolicy = FaceRecognitionPolicy()) {
        self.policy = policy
    }

    func recognize(images: [URL], references: [String: URL]) async throws -> FaceRecognitionBatch {
        guard !references.isEmpty else {
            throw StudioError.message("Choose a reference photo for each person in Concepts first.")
        }
        try await prepareModel()
        var embeddings: [String: [Float]] = [:]
        var referenceWarnings: [String: [String]] = [:]
        for (trigger, url) in references.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let image = try Self.image(url)
            let faces = try detect(image)
            guard faces.count == 1, let face = faces.first else {
                referenceWarnings[trigger] = ["Choose a reference with exactly one visible face."]
                continue
            }
            var warnings = face.referenceWarnings
            if let reason = face.reviewReason { warnings.append(reason) }
            referenceWarnings[trigger] = warnings
            guard face.reviewReason == nil else { continue }
            embeddings[trigger] = try embedding(image: image, points: face.points)
        }
        guard !embeddings.isEmpty else {
            throw StudioError.message("The reference faces need review. Choose clear, upright photos with one face.")
        }
        var samples: [String: FaceRecognitionResult] = [:]
        for url in images {
            try Task.checkCancellation()
            guard !Sources.isVideo(Sources.suffix(of: url.lastPathComponent)) else {
                samples[url.lastPathComponent] = FaceRecognitionResult(reviewReason: "Review video subjects manually")
                continue
            }
            let image = try Self.image(url), detected = try detect(image)
            var faces: [RecognizedFace] = []
            for face in detected {
                try Task.checkCancellation()
                guard face.reviewReason == nil else {
                    faces.append(RecognizedFace(box: face.box, scores: [], reviewReason: face.reviewReason))
                    continue
                }
                let vector = try embedding(image: image, points: face.points)
                var scores = embeddings.map { trigger, reference in
                    let similarity = zip(vector, reference).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    return FaceIdentityScore(
                        trigger: trigger, similarity: similarity, band: policy.band(similarity: similarity)
                    )
                }.sorted { $0.similarity > $1.similarity }
                let ambiguous = scores.filter { $0.band == .match }.count > 1
                if ambiguous {
                    for index in scores.indices where scores[index].band == .match {
                        scores[index].band = .needsReview
                    }
                }
                faces.append(RecognizedFace(
                    box: face.box, scores: scores,
                    reviewReason: ambiguous ? "More than one reference matches this face" : nil
                ))
            }
            samples[url.lastPathComponent] = FaceRecognitionResult(
                faces: faces, reviewReason: detected.isEmpty ? "No face detected" : nil
            )
        }
        return FaceRecognitionBatch(samples: samples, referenceWarnings: referenceWarnings)
    }

    func referenceWarnings(url: URL) throws -> [String] {
        let faces = try detect(Self.image(url))
        guard faces.count == 1, let face = faces.first else {
            return ["Choose a reference with exactly one visible face."]
        }
        return face.referenceWarnings + (face.reviewReason.map { [$0] } ?? [])
    }

    private func prepareModel() async throws {
        guard session == nil else { return }
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("ConceptStudio/Models/SFace", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(Self.modelRevision).onnx")
        if !FileManager.default.fileExists(atPath: file.path) {
            let (temporary, response) = try await URLSession.shared.download(from: Self.modelURL)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw StudioError.message("SFace could not be downloaded. Check your connection and try again.")
            }
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            guard data.count == Self.modelBytes, VisionInspector.contentHash(data) == Self.modelSHA256 else {
                throw StudioError.message("The SFace download is incomplete or changed. Download it again.")
            }
            try AtomicFile.write(data, to: file)
        }
        try Task.checkCancellation()
        let environment = try ORTEnv(loggingLevel: .error)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setLogSeverityLevel(.error)
        try options.setGraphOptimizationLevel(.all)
        // The original ONNX lists weights as graph inputs. CPU execution handles those
        // initializers directly without rewriting the downloaded model.
        let session = try ORTSession(env: environment, modelPath: file.path, sessionOptions: options)
        self.environment = environment
        self.session = session
    }

    private func embedding(image: CGImage, points: [CGPoint]) throws -> [Float] {
        guard let session else { throw StudioError.message("Load SFace before matching faces.") }
        let tensor = try Self.alignedRGB(image: image, points: points)
        let data = tensor.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        let input = try ORTValue(tensorData: data, elementType: .float, shape: [1, 3, 112, 112])
        let names = try session.outputNames()
        let output = try session.run(withInputs: ["data": input], outputNames: Set(names), runOptions: nil)
        guard let name = names.first, let value = output[name] else {
            throw StudioError.message("SFace returned no face embedding.")
        }
        let bytes = try value.tensorData() as Data
        var vector = [Float](repeating: 0, count: bytes.count / MemoryLayout<Float>.size)
        _ = vector.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard vector.count == 128, norm.isFinite, norm > 0 else {
            throw StudioError.message("SFace could not describe this face. Review the sample manually.")
        }
        return vector.map { $0 / norm }
    }

    private struct DetectedFace {
        var box: CGRect
        var points: [CGPoint]
        var reviewReason: String?
        var referenceWarnings: [String]
    }

    private func detect(_ image: CGImage) throws -> [DetectedFace] {
        let rectangles = VNDetectFaceRectanglesRequest()
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([rectangles])
        let observations = rectangles.results ?? []
        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.revision = VNDetectFaceLandmarksRequestRevision3
        landmarks.inputFaceObservations = observations
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = observations
        try handler.perform([landmarks, quality])
        let size = CGSize(width: image.width, height: image.height)
        var result: [DetectedFace] = []
        for face in observations.sorted(by: { $0.boundingBox.midX < $1.boundingBox.midX }) {
            let box = face.boundingBox
            let marked = landmarks.results?.first { $0.boundingBox == box }
            let captureQuality = quality.results?.first { $0.boundingBox == box }?.faceCaptureQuality
            var warnings: [String] = []
            if min(box.width * size.width, box.height * size.height) < policy.minimumReferencePixels {
                warnings.append("Small reference face: choose one at least 100 pixels across.")
            }
            if let captureQuality, captureQuality < policy.minimumReferenceQuality {
                warnings.append("Low reference clarity: choose a sharper, well-lit face.")
            }
            let roll = abs(face.roll?.doubleValue ?? 0) * 180 / .pi
            let points = Self.fivePoints(marked?.landmarks, size: size)
            var reason: String?
            if roll > policy.maximumRollDegrees { reason = "Face tilted more than 35°" }
            if let points {
                let spacing = hypot(points[0].x - points[1].x, points[0].y - points[1].y)
                if spacing < box.height * size.height * policy.minimumEyeSpacingRatio {
                    reason = "Face landmarks overlap or have collapsed"
                }
            } else { reason = "Face landmarks could not be located" }
            result.append(DetectedFace(
                box: box, points: points ?? [], reviewReason: reason, referenceWarnings: warnings
            ))
        }
        return result
    }

    private static func fivePoints(_ landmarks: VNFaceLandmarks2D?, size: CGSize) -> [CGPoint]? {
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            region?.pointsInImage(imageSize: size).map { CGPoint(x: $0.x, y: size.height - $0.y) } ?? []
        }
        let left = points(landmarks?.leftEye), right = points(landmarks?.rightEye)
        let nose = points(landmarks?.nose), lips = points(landmarks?.outerLips)
        guard !left.isEmpty, !right.isEmpty, !nose.isEmpty, lips.count >= 2 else { return nil }
        var first = FaceAlignment.mean(left), second = FaceAlignment.mean(right)
        let mouth = FaceAlignment.mean(lips), eye = FaceAlignment.mean([first, second])
        let dx = mouth.x - eye.x, dy = mouth.y - eye.y, length = hypot(dx, dy)
        guard length > 0.001 else { return nil }
        func projection(_ point: CGPoint) -> Double {
            (point.x * dy - point.y * dx) / length
        }
        if projection(first) > projection(second) { swap(&first, &second) }
        guard let mouthLeft = lips.min(by: { projection($0) < projection($1) }),
              let mouthRight = lips.max(by: { projection($0) < projection($1) }) else { return nil }
        return [first, second, FaceAlignment.mean(nose), mouthLeft, mouthRight]
    }

    static func image(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 8192,
              ] as CFDictionary) else {
            throw StudioError.message("This image cannot be opened for face recognition.")
        }
        return image
    }

    /// NCHW RGB at 0–255 scale: SFace does not use ArcFace's [-1, 1] normalization.
    static func alignedRGB(image: CGImage, points: [CGPoint]) throws -> [Float] {
        let transform = try FaceAlignment(points: points), width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw StudioError.message("The face image could not be prepared.") }
        var tensor = [Float](repeating: 0, count: 3 * 112 * 112)
        for y in 0 ..< 112 {
            for x in 0 ..< 112 {
                let point = transform.sourcePoint(x: Double(x), y: Double(y))
                let ix = Int(floor(point.x)), iy = Int(floor(point.y))
                let fx = Float(point.x - Double(ix)), fy = Float(point.y - Double(iy))
                for channel in 0 ..< 3 {
                    var value: Float = 0
                    for (xx, wx) in [(ix, 1 - fx), (ix + 1, fx)] {
                        for (yy, wy) in [(iy, 1 - fy), (iy + 1, fy)]
                            where xx >= 0 && xx < width && yy >= 0 && yy < height {
                            value += Float(pixels[(yy * width + xx) * 4 + channel]) * wx * wy
                        }
                    }
                    tensor[channel * 112 * 112 + y * 112 + x] = value
                }
            }
        }
        return tensor
    }
}
