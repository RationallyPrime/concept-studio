import Foundation
import PrevisCore

public enum PassKind: String, Codable, Sendable, CaseIterable { case clean, pose, layout, matte }

public struct ExportOptions: Sendable, Equatable {
    public var passes: Set<PassKind>

    public init(passes: Set<PassKind>) {
        self.passes = passes
    }

    /// All four passes.
    public static let standard = ExportOptions(passes: Set(PassKind.allCases))
}

public struct ExportProgress: Sendable, Equatable {
    public var step: String
    public var fractionCompleted: Double

    public init(step: String, fractionCompleted: Double) {
        self.step = step
        self.fractionCompleted = fractionCompleted
    }
}

public struct ExportedPackage: Sendable {
    public var url: URL
    public var manifest: PackageManifest

    public init(url: URL, manifest: PackageManifest) {
        self.url = url
        self.manifest = manifest
    }
}

/// Where a finished package goes: the extension seam later destinations plug into.
public protocol PackageDestination: Sendable {
    /// Where the exporter builds the package, on the destination's volume so delivery is a move.
    func stagingDirectory() throws -> URL
    func deliver(staged: URL, manifest: PackageManifest) async throws -> URL
}

/// Delivers to `<parent>/<shot-slug>/<YYYYMMDD-HHMMSS>-<N>f-<W>x<H>/`.
public struct FolderDestination: PackageDestination {
    public let parent: URL

    public init(parent: URL) {
        self.parent = parent
    }

    public func stagingDirectory() throws -> URL {
        let staging = parent.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    public func deliver(staged: URL, manifest: PackageManifest) async throws -> URL {
        let shotFolder = parent.appendingPathComponent(PackageNames.slug(manifest.shot.name), isDirectory: true)
        try FileManager.default.createDirectory(at: shotFolder, withIntermediateDirectories: true)
        let name = "\(PackageNames.stamp(Date()))-\(manifest.frameCount)f-"
            + "\(manifest.canvas.width)x\(manifest.canvas.height)"
        var target = shotFolder.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = shotFolder.appendingPathComponent("\(name)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.moveItem(at: staged, to: target)
        return target
    }
}

/// File and folder names inside packages.
enum PackageNames {
    /// Lowercase ASCII with dashes; "shot" when nothing usable is left.
    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        let words = folded.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        return words.isEmpty ? "shot" : words.joined(separator: "-")
    }

    /// Entity slugs in entity order; repeats get -2, -3, ….
    static func entitySlugs(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { name in
            let base = slug(name)
            let count = (seen[base] ?? 0) + 1
            seen[base] = count
            return count == 1 ? base : "\(base)-\(count)"
        }
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
