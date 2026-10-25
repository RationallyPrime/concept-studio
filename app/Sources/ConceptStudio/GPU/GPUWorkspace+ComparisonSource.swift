import ConceptCore
import Foundation

extension GPUWorkspace {
    /// Checkpoints available without the original rental: saved files and the published final LoRA.
    func comparisonCheckpoints(for run: TrainingRun) -> [RunFile] {
        var files = currentVolumeID == run.volumeID ? run.checkpoints : []
        if let folder = localComparisonFolder(run),
           let listing = FileManager.default.enumerator(
               at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
           ) {
            for case let file as URL in listing where file.pathExtension == "safetensors" {
                guard let values = try? file.resourceValues(forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]),
                    values.isRegularFile == true, values.isSymbolicLink != true,
                    file.resolvingSymlinksInPath().path.hasPrefix(folder.path + "/") else { continue }
                let path = String(file.resolvingSymlinksInPath().path.dropFirst(folder.path.count + 1))
                if !files.contains(where: { $0.path == path }) {
                    files.append(RunFile(path: path, size: values.fileSize ?? 0, sha256: ""))
                }
            }
        }
        if publishedComparisonRepo(run) != nil {
            files.append(RunFile(path: "published.safetensors", size: 0, sha256: ""))
        }
        return files
    }

    func comparisonCheckpoint(for run: TrainingRun, agent: any PodAgent) async throws -> RunFile {
        if currentVolumeID == run.volumeID,
           let files = try? await agent.runFiles(runID: run.runID),
           let checkpoint = RunArtifacts.newest(files.filter { $0.path.hasSuffix(".safetensors") }) {
            return checkpoint
        }
        let available = comparisonCheckpoints(for: run)
        if let checkpoint = RunArtifacts.newest(available.filter { $0.path != "published.safetensors" })
            ?? available.first(where: { $0.path == "published.safetensors" }) { return checkpoint }
        throw StudioError
            .message("This run needs its published LoRA, a copy saved on this Mac, or its original storage.")
    }

    func portableComparisonSource(
        _ run: TrainingRun, checkpoint: RunFile, agent: any PodAgent, uploadID: String
    ) async throws -> JSONObject? {
        if currentVolumeID == run.volumeID, checkpoint.path != "published.safetensors",
           let files = try? await agent.runFiles(runID: run.runID),
           files.contains(where: { $0.path == checkpoint.path }) {
            return nil
        }
        var config = run.params
        config["run_id"] = .string(run.runID)
        for key in ["hf_token", "api_key"] {
            config.removeValue(forKey: key)
        }
        if let folder = localComparisonFolder(run), checkpoint.path != "published.safetensors" {
            let file = folder.appendingPathComponent(checkpoint.path).standardizedFileURL
            guard file.resolvingSymlinksInPath().path.hasPrefix(folder.path + "/"),
                  let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                throw StudioError.message("The selected LoRA is no longer saved in this project.")
            }
            message = "Uploading this run's saved LoRA to the connected GPU…"
            try await agent.upload(
                name: uploadID, fileName: "comparison-lora.safetensors", from: file, size: Int64(values.fileSize ?? 0)
            )
            let recipe = folder.appendingPathComponent("native-config.json")
            if FileManager.default.fileExists(atPath: recipe.path) {
                let size = try recipe.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                try await agent.upload(
                    name: uploadID,
                    fileName: "comparison-recipe.json",
                    from: recipe,
                    size: Int64(size)
                )
            } else if let row = run.modelRow(in: modelTable),
                      row.hooks.generator == .aitoolkitArchImage || row.hooks.generator == .minimaxH3 {
                // Older saved copies may lack the effective native recipe, which publication retains as config.yaml.
                if let repo = publishedComparisonRepo(run) { return ["config": .object(config), "repo": .string(repo)] }
                throw StudioError.message("This saved LoRA needs its native-config.json recipe. "
                    + "Retrieve the run again from its original storage or use its published repository.")
            }
            return ["config": .object(config), "upload": .string(uploadID)]
        }
        if let repo = publishedComparisonRepo(run) { return ["config": .object(config), "repo": .string(repo)] }
        throw StudioError
            .message(
                "The selected checkpoint is unavailable. Use a LoRA saved on this Mac or published to Hugging Face."
            )
    }

    private func localComparisonFolder(_ run: TrainingRun) -> URL? {
        guard let saved = run.localSavedFolder, let expected = try? resultsFolder(for: run.runID) else { return nil }
        let folder = URL(fileURLWithPath: saved).resolvingSymlinksInPath()
        return folder.path == expected.path ? folder : nil
    }

    private func publishedComparisonRepo(_ run: TrainingRun) -> String? {
        if case let .pushed(repo) = run.result?.state { return repo }
        return nil
    }
}
