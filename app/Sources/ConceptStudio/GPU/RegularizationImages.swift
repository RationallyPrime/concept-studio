import ConceptCore
import Foundation

/// Class images use the normal image importer and project captioner, without borrowing original sidecars.
enum RegularizationImages {
    static func samples(from folder: URL) throws -> [Sample] {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: .skipsHiddenFiles
        ).filter {
            let suffix = Sources.suffix(of: $0.lastPathComponent).lowercased()
            return Sources.imageSuffixes.contains(suffix) || MediaEditor.convertibleImageSuffixes.contains(suffix)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw StudioError.message("Choose a folder containing class images.") }
        var total: Int64 = 0
        return try files.enumerated().map { index, file in
            try Task.checkCancellation()
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let size = Int64(info.fileSize ?? 0)
            total += size
            guard info.isRegularFile == true, size > 0, size <= LocalTrainingDataset.maximumFileBytes,
                  total <= LocalTrainingDataset.maximumDatasetBytes else {
                throw StudioError
                    .message("Class images must be regular files of at most 2 GiB, totalling at most 20 GiB.")
            }
            let imported = try MediaEditor.normalizedImport(
                Data(contentsOf: file), name: String(format: "class-%06d", index + 1) + "." + file.pathExtension
            )
            return Sample(sampleID: imported.name, data: imported.data, suffix: Sources.suffix(of: imported.name))
        }
    }

    static func snapshot(samples: [Sample], captions: [String: String]) throws -> LocalTrainingDataset {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("studio-class-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            var rows: [MetadataRow] = []
            for sample in samples {
                guard let caption = captions[sample.sampleID], !caption.isBlank else { continue }
                try sample.data.write(to: folder.appendingPathComponent(sample.sampleID))
                try caption.write(
                    to: folder.appendingPathComponent(Sources.stem(of: sample.sampleID) + ".txt"),
                    atomically: true, encoding: .utf8
                )
                rows.append(MetadataRow(fileName: sample.sampleID, caption: caption, record: nil))
            }
            guard !rows.isEmpty else {
                throw StudioError.message("The captioner found none of the regularisation images usable.")
            }
            try ImageFolderMetadata.serialize(rows).write(to: folder.appendingPathComponent("metadata.jsonl"))
            let files = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.fileSizeKey]
            )
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
                try LocalTrainingDataset.File(
                    name: url.lastPathComponent, url: url,
                    size: Int64(url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0),
                    sha256: RunArtifacts.sha256(of: url)
                )
            }
            return LocalTrainingDataset(
                folder: folder, files: files, digest: LocalTrainingDataset.inputDigest(files),
                containsVideo: false, itemCount: rows.count
            )
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

extension GPUWorkspace {
    func captionedOwnRegularization(
        _ params: JSONObject, plan: TrainingPlan, captioning: RegularizationCaptioning, agent: any PodAgent
    ) async throws -> JSONObject {
        guard let folder = regularizationFolder else {
            throw StudioError.message("Choose your folder of regularisation images in Advanced.")
        }
        message = "Reading your regularisation images."
        let samples = try RegularizationImages.samples(from: folder)
        if captioning.usesPodCaptionServer {
            try await ensureCaptionServer(agent, plan: plan, services: agent.services())
        }
        let captions = try await captioning.captioner.captions(of: samples) { done in
            await MainActor.run { self.message = "Describing regularisation images: \(done) of \(samples.count)" }
        }
        let snapshot = try RegularizationImages.snapshot(samples: samples, captions: captions)
        defer { snapshot.remove() }
        let name = "class-" + UUID().uuidString.prefix(12).lowercased()
        try await installTrainingDataset(snapshot, repo: "", revision: nil, name: name, agent: agent)
        var result = params
        var block = params["regularization"]?.objectValue ?? [:]
        block["path"] = .string("/workspace/datasets/" + name)
        result["regularization"] = .object(block)
        return result
    }
}
