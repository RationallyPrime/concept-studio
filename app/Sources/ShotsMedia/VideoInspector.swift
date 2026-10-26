import AVFoundation
import PrevisCore
import Synchronization

/// What a video file actually contains, read back after writing.
struct VideoFacts: Equatable {
    var frameCount: Int
    var width: Int
    var height: Int
    var presentationTimes: [CMTime]
    var codec: String
    var colorPrimaries: String?
    var transferFunction: String?
    var matrix: String?

    var isBT709: Bool {
        colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String
            && transferFunction == kCVImageBufferTransferFunction_ITU_R_709_2 as String
            && matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
    }
}

/// Reads videos back, for the self-test and the package validator.
enum VideoInspector {
    /// `AVAssetReader` reads synchronously and waits on CoreMedia's own workers. With as many concurrent reads as
    /// Swift's cooperative pool has threads (three on the CI runner), every read held a cooperative thread and none
    /// returned. Keep the reads off the cooperative executor, as `MediaEditor` does for the app's clips.
    private static let readerQueue = DispatchQueue(label: "ShotsMedia.VideoInspector", qos: .userInitiated)

    static func facts(_ url: URL) async throws -> VideoFacts {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ShotsMediaError("\(url.lastPathComponent) has no video track.")
        }
        let (size, descriptions) = try await track.load(.naturalSize, .formatDescriptions)
        var facts = VideoFacts(
            frameCount: 0, width: Int(size.width.rounded()), height: Int(size.height.rounded()),
            presentationTimes: [], codec: "?"
        )
        if let description = descriptions.first {
            facts.codec = Self.fourCharacterCode(CMFormatDescriptionGetMediaSubType(description))
            let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
            facts.colorPrimaries = extensions[kCVImageBufferColorPrimariesKey as String] as? String
            facts.transferFunction = extensions[kCVImageBufferTransferFunctionKey as String] as? String
            facts.matrix = extensions[kCVImageBufferYCbCrMatrixKey as String] as? String
        }
        let name = url.lastPathComponent
        let cancelled = Mutex(false)
        facts.presentationTimes = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                readerQueue.async {
                    continuation.resume(with: Result {
                        try presentationTimes(asset: asset, track: track, name: name) {
                            if cancelled.withLock({ $0 }) { throw CancellationError() }
                        }
                    })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        facts.frameCount = facts.presentationTimes.count
        return facts
    }

    /// Every frame's presentation time in `track`, sorted. Blocks while reading; call it only on `readerQueue`.
    private static func presentationTimes(
        asset: AVURLAsset, track: AVAssetTrack, name: String, checkCancellation: () throws -> Void
    ) throws -> [CMTime] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw ShotsMediaError("\(name) can't be read: \(reader.error?.localizedDescription ?? "?").")
        }
        defer { reader.cancelReading() }
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            try checkCancellation()
            // Passthrough reading also yields empty marker buffers; only real samples are frames.
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            times.append(CMSampleBufferGetPresentationTimeStamp(sample))
        }
        guard reader.status == .completed else {
            throw ShotsMediaError("\(name) stopped reading early: \(reader.error?.localizedDescription ?? "?").")
        }
        return times.sorted { CMTimeCompare($0, $1) < 0 }
    }

    /// Plain-sentence problems with a video that should hold `frameCount` frames at `size`, presented at i/24.
    static func problems(_ url: URL, frameCount: Int, size: PixelSize) async -> [String] {
        do {
            return try await problems(in: facts(url), name: url.lastPathComponent, frameCount: frameCount, size: size)
        } catch {
            return [error.localizedDescription]
        }
    }

    static func problems(in facts: VideoFacts, name: String, frameCount: Int, size: PixelSize) -> [String] {
        var problems: [String] = []
        if facts.frameCount != frameCount {
            problems.append("\(name) has \(facts.frameCount) frames instead of \(frameCount).")
        }
        if facts.width != size.width || facts.height != size.height {
            problems.append("\(name) is \(facts.width) × \(facts.height) instead of \(size.width) × \(size.height).")
        }
        for index in checkedFrames(frameCount) where index < facts.frameCount {
            if CMTimeCompare(facts.presentationTimes[index], CMTime(value: CMTimeValue(index), timescale: 24)) != 0 {
                problems.append(
                    "\(name) shows frame \(index) at \(facts.presentationTimes[index].seconds) s, not \(index)/24 s."
                )
            }
        }
        if facts.codec != "avc1" {
            problems.append("\(name) is encoded as \(facts.codec), not H.264.")
        }
        if !facts.isBT709 {
            problems.append("\(name) lacks BT.709 colour tags.")
        }
        return problems
    }

    /// The first, middle and last frames: where presentation times are checked.
    static func checkedFrames(_ frameCount: Int) -> [Int] {
        frameCount > 0 ? Array(Set([0, frameCount / 2, frameCount - 1])).sorted() : []
    }

    private static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }
}
