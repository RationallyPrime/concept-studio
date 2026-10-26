import Foundation
import ImageIO
import PrevisCore

/// Checks a package against its own manifest, for the passes it lists (CONTRACTS section 8.3). An empty result
/// means valid.
public enum PackageValidator {
    public static func problems(at packageURL: URL) async -> [String] {
        guard let data = try? Data(contentsOf: packageURL.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data)
        else { return ["manifest.json is missing or doesn't decode."] }
        guard manifest.format == PackageManifest.formatName,
              manifest.formatVersion == PackageManifest.currentFormatVersion
        else {
            return [
                "manifest.json is \(manifest.format) version \(manifest.formatVersion), "
                    + "which this validator doesn't know.",
            ]
        }
        var problems: [String] = []
        if !FrameGrid.isValid(manifest.frameCount) {
            problems.append("The frame count \(manifest.frameCount) is off the 17k + 5 grid.")
        }
        let size = manifest.canvas.pixelSize
        for file in manifest.files {
            let url = packageURL.appendingPathComponent(file.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                problems.append("\(file.path) is listed but missing.")
                continue
            }
            switch url.pathExtension {
            case "png": problems += stillProblems(url, path: file.path, size: size)
            case "mp4": problems += await videoProblems(
                    url,
                    path: file.path,
                    frameCount: manifest.frameCount,
                    size: size
                )
            default: break
            }
        }
        problems += guideProblems(manifest)
        if manifest.passes.contains(.matte) {
            problems += matteProblems(manifest, packageURL: packageURL)
        }
        return problems
    }

    private static func stillProblems(_ url: URL, path: String, size: PixelSize) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return ["\(path) isn't a readable image."] }
        guard width == size.width, height == size.height else {
            return ["\(path) is \(width) × \(height), not the canvas's \(size.width) × \(size.height)."]
        }
        return []
    }

    private static func videoProblems(_ url: URL, path: String, frameCount: Int, size: PixelSize) async -> [String] {
        do {
            return try await VideoInspector.problems(
                in: VideoInspector.facts(url),
                name: path,
                frameCount: frameCount,
                size: size
            )
        } catch {
            return ["\(path) can't be read: \(error.localizedDescription)"]
        }
    }

    /// Each still-producing pass needs its first and last guide.
    private static func guideProblems(_ manifest: PackageManifest) -> [String] {
        let variants: [PassKind: PackageFile.Variant] = [.clean: .clean, .pose: .pose, .layout: .layout]
        return manifest.passes.compactMap { pass in variants[pass].map { (pass, $0) } }.flatMap { pass, variant in
            [PackageFile.Position.first, .last].compactMap { position in
                manifest.files.contains { $0.role == .guide && $0.variant == variant && $0.position == position }
                    ? nil : "The \(pass.rawValue) pass has no \(position.rawValue) guide still."
            }
        }
    }

    /// With the matte pass, every actor in `shot.json` needs a matte video.
    private static func matteProblems(_ manifest: PackageManifest, packageURL: URL) -> [String] {
        guard let data = try? Data(contentsOf: packageURL.appendingPathComponent("shot.json")),
              let description = try? JSONDecoder().decode(DescribedSubjects.self, from: data)
        else { return ["shot.json is missing or doesn't decode, so the actors' mattes can't be checked."] }
        return description.subjects.filter(\.isActor).compactMap { actor in
            manifest.files.contains { $0.role == .matte && $0.entityID == actor.entityID && $0.frameCount != nil }
                ? nil : "\(actor.name) has no matte video."
        }
    }
}

/// The part of `shot.json` the validator reads.
private struct DescribedSubjects: Decodable {
    var subjects: [DescribedSubject]
}

private struct DescribedSubject: Decodable {
    var entityID: EntityID, name: String, isActor: Bool
}
