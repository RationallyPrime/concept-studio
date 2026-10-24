import AVFoundation
@testable import ConceptStudio
import CoreVideo
import Foundation
import Testing

/// Two seconds of the bundled fictional demo face, with modest camera motion and an optional blank middle.
enum SFaceClipFixture {
    static func write(_ image: CGImage, to url: URL, blankMiddle: Bool = false) async throws {
        let size = 640
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input)
        try #require(writer.canAdd(input))
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0 ..< 48 {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? StudioError.message("Synthetic encoder failed") }
                try await Task.sleep(for: .milliseconds(10))
            }
            let buffer = try pixelBuffer(
                image,
                size: size,
                index: index,
                blank: blankMiddle && (20 ..< 28).contains(index)
            )
            try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 24)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }

    private static func pixelBuffer(_ image: CGImage, size: Int, index: Int, blank: Bool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(
            kCFAllocatorDefault, size, size, kCVPixelFormatType_32ARGB,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ] as CFDictionary,
            &buffer
        ) == kCVReturnSuccess)
        let pixel = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let context = try #require(CGContext(
            data: CVPixelBufferGetBaseAddress(pixel), width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        if !blank {
            let progress = Double(index) / 47
            let scale = min(Double(size) / Double(image.width), Double(size) / Double(image.height)) *
                (1 + 0.06 * progress)
            let width = Double(image.width) * scale, height = Double(image.height) * scale
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(
                x: (Double(size) - width) / 2 + 8 * (progress - 0.5),
                y: (Double(size) - height) / 2, width: width, height: height
            ))
        }
        return pixel
    }
}
