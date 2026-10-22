import ConceptCore
import Foundation

// Upscaling and restoration with SeedVR2 on the rented cloud GPU (POD-SPEC 3.9). The person picks images and
// clips on the Images screen, the cloud GPU upscales them, and each result waits beside its original until the
// person keeps or discards it. A kept result replaces the sample the way an approved crop does; the original is
// kept in the project and can be put back at any time.

/// The two SeedVR2 sizes the pod offers, with what the person needs to know before choosing one.
enum UpscaleModel: String, CaseIterable, Codable, Identifiable {
    case standard = "3b"
    case large = "7b"

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .standard: "SeedVR2 3B"
        case .large: "SeedVR2 7B"
        }
    }

    var summary: String {
        switch self {
        case .standard: "Faster, and the usual choice."
        case .large: "More detail on badly damaged media; slower and uses more graphics memory."
        }
    }

    /// Decimal GB the first use downloads to the cloud GPU's storage: the FP16 model and its VAE.
    var firstDownloadGB: Double {
        switch self {
        case .standard: 7.3
        case .large: 17.0
        }
    }

    /// The model card on the Hub, which carries the licence.
    var modelCard: URL {
        switch self {
        case .standard: URL(string: "https://huggingface.co/ByteDance-Seed/SeedVR2-3B")!
        case .large: URL(string: "https://huggingface.co/ByteDance-Seed/SeedVR2-7B")!
        }
    }

    static let licenseName = "Apache License 2.0"
    static let licenseNotice = "SeedVR2 is by ByteDance Seed and licensed under the Apache License 2.0, "
        + "like the program that runs it on the cloud GPU (ComfyUI-SeedVR2_VideoUpscaler)."
    /// From the model card's own limitations, in the terms that matter for training data.
    static let caution = "SeedVR2 can invent detail, most often on media that was only lightly degraded. "
        + "Compare each result with its original, especially faces: a LoRA learns whatever detail it is shown."
}

/// The size results are made at: the short side of the largest training resolution the model offers, so a
/// later change of resolution bucket does not need a second upscale. The longer side is capped at twice that.
struct UpscaleTarget: Equatable {
    let shortSide: Int

    var longSideLimit: Int {
        shortSide * 2
    }

    init(row: ModelRow) {
        shortSide = row.resolution.choices.max() ?? 1024
    }

    init(shortSide: Int) {
        self.shortSide = shortSide
    }

    /// Below the target size: the trainer would have to enlarge this sample to fill its largest bucket.
    func isBelow(_ analysis: ImageAnalysis?) -> Bool {
        guard let analysis, analysis.width > 0, analysis.height > 0 else { return false }
        return min(analysis.width, analysis.height) < shortSide
    }
}

/// A result back from the cloud GPU, not yet kept or discarded. The file lives in the project's app folder.
struct PendingUpscale: Codable, Equatable, Identifiable {
    /// The sample it was made from, by its id when the upscale started.
    var sourceID: String
    /// Relative to the project's app folder: `upscaled/<run-id>/<file>`.
    var resultPath: String
    var model: UpscaleModel
    var shortSide: Int
    var created: Date

    var id: String {
        sourceID
    }

    func resultURL(in project: URL) -> URL {
        ProjectAppState.folder(in: project).appendingPathComponent(resultPath)
    }
}

/// A kept result: how to put the original back.
struct UpscaleRecord: Codable, Equatable {
    var originalID: String
    /// Relative to the project's app folder: the edits folder holding the original and its sidecars.
    var backupPath: String
    var previousSelection: MediaSelection?
    var model: UpscaleModel
    var shortSide: Int
    var kept: Date
}

extension ProjectImage {
    /// The sample at `url` with the caption and response record read from the sidecars beside it.
    static func reading(_ url: URL) -> ProjectImage {
        let stem = url.deletingPathExtension()
        let caption = (try? String(contentsOf: stem.appendingPathExtension("txt"), encoding: .utf8)) ?? ""
        let record = (try? Data(contentsOf: stem.appendingPathExtension("json")))
            .flatMap { try? JSONValue(parsing: $0) }
            .flatMap { try? ResponseRecord(json: $0, sampleID: url.lastPathComponent) }
        return ProjectImage(
            url: url, caption: caption, status: record?.status, isFinal: record?.isHumanFinal ?? false,
            isImported: isImported(record, caption: caption)
        )
    }
}

extension StudioProject {
    var upscaledDirectory: URL {
        ProjectAppState.folder(in: directory).appendingPathComponent("upscaled", isDirectory: true)
    }

    /// The name a kept result takes: the original's stem with the result's extension, or `-upscaled` added
    /// when another sample already has that name.
    func upscaledName(for sourceID: String, resultExtension: String) -> String {
        let plain = Sources.stem(of: sourceID) + "." + resultExtension
        guard plain != sourceID, allMedia.contains(where: { $0.id == plain }) else { return plain }
        return Sources.stem(of: sourceID) + "-upscaled." + resultExtension
    }

    /// Replaces the sample with its upscaled result. Its locator mapping carries over (locators are sentences,
    /// and upscaling keeps the composition); its caption stays with the original, as for an approved crop.
    mutating func keepUpscale(_ pending: PendingUpscale) throws {
        guard images.contains(where: { $0.id == pending.sourceID }) else {
            throw StudioError.message("Include \(pending.sourceID) before keeping its upscaled version.")
        }
        let result = pending.resultURL(in: directory)
        let name = upscaledName(for: pending.sourceID, resultExtension: result.pathExtension.lowercased())
        let previous = mediaState.selections[pending.sourceID]
        let mapping = job.mapping(for: pending.sourceID)
        try approveTarget(
            id: pending.sourceID, sourceFile: result, name: name,
            selection: previous ?? MediaSelection(originalName: pending.sourceID)
        )
        guard case let .replacement(_, _, _, _, backup, _, _, _) = curationUndo.last else { return }
        if let mapping { try? job.setMapping(mapping, for: name) }
        mediaState.pendingUpscales.removeAll { $0.sourceID == pending.sourceID }
        mediaState.upscaled[name] = UpscaleRecord(
            originalID: pending.sourceID, backupPath: Self.appRelative(backup, in: directory),
            previousSelection: previous, model: pending.model, shortSide: pending.shortSide, kept: Date()
        )
        try save()
        try? FileManager.default.removeItem(at: result)
    }

    mutating func discardUpscale(_ sourceID: String) throws {
        guard let pending = mediaState.pendingUpscales.first(where: { $0.sourceID == sourceID }) else { return }
        mediaState.pendingUpscales.removeAll { $0.sourceID == sourceID }
        try save()
        try? FileManager.default.removeItem(at: pending.resultURL(in: directory))
    }

    /// Puts the original back in place of a kept result, at any time and after relaunch. The result and its
    /// sidecars move to the edits folder rather than being deleted.
    mutating func revertUpscale(_ id: String) throws {
        guard let record = mediaState.upscaled[id], let current = allMedia.first(where: { $0.id == id }) else {
            throw StudioError.message("\(id) has no original to put back.")
        }
        let backup = ProjectAppState.folder(in: directory).appendingPathComponent(record.backupPath)
        guard FileManager.default.fileExists(atPath: backup.appendingPathComponent(record.originalID).path) else {
            throw StudioError.message("The original of \(id) is missing from the project's edits folder.")
        }
        let wasIncluded = isIncluded(id)
        let folder = wasIncluded ? imagesDirectory : excludedDirectory
        let previous = self
        let discarded = ProjectAppState.folder(in: directory).appendingPathComponent("edits/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: discarded, withIntermediateDirectories: true)
        _ = try moveTarget(current.url, to: discarded)
        let restored: URL
        do { restored = try moveTarget(backup.appendingPathComponent(record.originalID), to: folder) } catch {
            _ = try? moveTarget(discarded.appendingPathComponent(id), to: folder)
            throw error
        }
        do {
            let original = ProjectImage.reading(restored)
            images.removeAll { $0.id == id }; excludedImages.removeAll { $0.id == id }
            if wasIncluded { images.append(original) } else { excludedImages.append(original) }
            let mapping = job.mapping(for: id)
            job.samples.removeValue(forKey: id)
            if wasIncluded { try job.setMapping(job.mappingIncludingWholeTargets(mapping), for: record.originalID) }
            mediaState.selections[id] = nil
            mediaState.selections[record.originalID] = record.previousSelection
            mediaState.upscaled[id] = nil
            curationUndo.removeAll { $0.replacedIDs.contains(id) }
            try save()
        } catch {
            _ = try? moveTarget(restored, to: backup)
            _ = try? moveTarget(discarded.appendingPathComponent(id), to: folder)
            self = previous
            try? save()
            throw error
        }
    }

    private static func appRelative(_ url: URL, in project: URL) -> String {
        let root = ProjectAppState.folder(in: project).standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }
}
