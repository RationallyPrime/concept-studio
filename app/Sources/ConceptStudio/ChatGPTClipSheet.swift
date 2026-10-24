import ConceptCore
import Foundation
import UniformTypeIdentifiers

/// Visual evidence for one original clip; the training target, profile and sidecar ID remain the clip's.
struct ChatGPTClipSheet: Sendable {
    let jpeg: Data
    let duration: Double
    let frameTimes: [Double]
    let hasAudio: Bool

    var content: [UserContent] {
        let times = frameTimes.enumerated().map { "\($0.offset + 1): \(Self.timestamp($0.element)) s" }
            .joined(separator: ", ")
        let audio = hasAudio
            ? "The clip has an audio track, but it was not transmitted or inspected. Do not invent speech, sound, "
            + "music or silence. Follow the project's audio-training policy; "
            + "unavailable audio is not evidence of silence."
            : "The selected clip has no audio track (confirmed from the file). Both H3 audio fields can be N/A."
        return [
            .text("""
            This is ONE video training target represented by \(frameTimes.count) sampled frames in a single sheet, \
            not independent photographs. The selected clip lasts \(Self.timestamp(duration)) seconds. Read numbered \
            frames left to right, then top to bottom; each header labels the frame directly below it. \
            Actual clip-relative sample times: \(times).
            Describe changes supported by this ordered sequence in the project's clip profile, producing one caption \
            for the clip. Do not describe the sheet, its numbers or layout in the caption. Sample times are not exact \
            cut times. Do not invent action between samples, unseen events or precise transition times. \
            Repeated frames do not establish motion. \(audio)
            """),
            .image(data: jpeg, mediaType: "image/jpeg"),
        ]
    }

    /// The count is explicit for the paired benchmark; the production default is finalized from its results.
    static func prepare(
        data: Data, mediaType: String, frameCount: Int = 9,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> ChatGPTClipSheet {
        guard [9, 16].contains(frameCount) else { throw StudioError.message("Choose nine or sixteen clip frames.") }
        guard let type = UTType(mimeType: mediaType), type.conforms(to: .movie),
              let suffix = type.preferredFilenameExtension else {
            throw StudioError.message("This clip format cannot be prepared for ChatGPT.")
        }
        try Task.checkCancellation()
        let file = temporaryDirectory.appendingPathComponent("conceptstudio-clip-\(UUID().uuidString).\(suffix)")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file, options: .atomic)
        try Task.checkCancellation()
        let info = try await MediaEditor.videoInfo(url: file)
        let frames = try await MediaEditor.frames(url: file, count: frameCount)
        try Task.checkCancellation()
        let tiles = frames.enumerated().map { (
            image: $0.element.image,
            label: "\($0.offset + 1) · \(timestamp($0.element.seconds)) s"
        ) }
        let jpeg = try NumberedContactSheet.jpeg(tiles, columns: frameCount == 9 ? 3 : 4)
        try Task.checkCancellation()
        return ChatGPTClipSheet(
            jpeg: jpeg,
            duration: info.duration,
            frameTimes: frames.map(\.seconds),
            hasAudio: info.hasAudio
        )
    }

    private static func timestamp(_ seconds: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }
}
