import AVFoundation
import CoreVideo
import PrevisCore

/// Writes frame-exact H.264 MP4s: frame `i` is presented at exactly i/24 s, the file ends at N/24 s, and the
/// stream carries BT.709 tags. Buffers come from the writer's own IOSurface pool, so the renderer draws straight
/// into what gets encoded. Lives on the main actor because the buffers never cross a task boundary.
@MainActor final class VideoWriter {
    let url: URL
    let size: PixelSize
    let frameCount: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    init(url: URL, size: PixelSize, frameCount: Int) throws {
        guard size.width > 0, size.height > 0, size.width.isMultiple(of: 2), size.height.isMultiple(of: 2) else {
            throw ShotsMediaError(
                "A video must have an even, positive width and height, not \(size.width) × \(size.height)."
            )
        }
        self.url = url
        self.size = size
        self.frameCount = frameCount
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(url: url, fileType: .mp4)
        writer.movieTimeScale = 24000
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 24,
                AVVideoMaxKeyFrameIntervalKey: 24,
                AVVideoAllowFrameReorderingKey: false,
                // About 0.25 bits per pixel: hard grey-box edges and skeleton lines stay clean.
                AVVideoAverageBitRateKey: max(2_000_000, size.width * size.height * 6),
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
        )
        guard writer.canAdd(input) else {
            throw ShotsMediaError("The video writer refused H.264 at \(size.width) × \(size.height).")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ShotsMediaError("The video writer couldn't start: \(Self.reason(writer.error)).")
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// A buffer from the writer's pool, ready to render into.
    func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer
        else { throw ShotsMediaError("The video writer has no frame buffer to render into.") }
        return buffer
    }

    /// Appends `buffer` as frame `frame`, presented at frame/24 s.
    func append(_ buffer: CVPixelBuffer, frame: Int) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(1))
        }
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 24)) else {
            throw ShotsMediaError("Writing frame \(frame) failed: \(Self.reason(writer.error)).")
        }
    }

    /// Ends the file at exactly frameCount/24 s, so the last frame lasts a full 1/24 s.
    func finish() async throws {
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: 24))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ShotsMediaError("Finishing the video failed: \(Self.reason(writer.error)).")
        }
    }

    /// Abandons the file and removes whatever was written.
    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    private static func reason(_ error: (any Error)?) -> String {
        error?.localizedDescription ?? "no reason given"
    }
}

extension ShotFrameRenderer {
    /// Renders every frame of `evaluator`'s shot in the canonical look and writes the clean reference video.
    /// Cancelling the task removes the partial file.
    func writeCleanVideo(
        of evaluator: ShotEvaluator,
        look: PrevisLook,
        to url: URL,
        progress: ((Int) -> Void)? = nil
    ) async throws {
        let first = evaluator.frame(0)
        let writer = try VideoWriter(url: url, size: first.canvas.pixelSize, frameCount: evaluator.frameCount)
        do {
            for index in 0 ..< evaluator.frameCount {
                try Task.checkCancellation()
                let buffer = try writer.makeBuffer()
                try await render(evaluator.frame(index), look: look, into: buffer)
                try await writer.append(buffer, frame: index)
                progress?(index)
            }
            try await writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
    }
}
