import ConceptCore
import Foundation

/// How far the cloud GPU has got with an upscale, from its log's `[upscale] ready k/N` lines.
struct UpscaleProgress: Equatable {
    let total: Int
    let ready: Int

    var text: String {
        "Upscaling on the cloud GPU: \(ready) of \(total) ready"
    }

    static func parse(log: String) -> UpscaleProgress? {
        let prefix = "[upscale] ready "
        for line in log.split(separator: "\n").reversed() where line.hasPrefix(prefix) {
            let counts = line.dropFirst(prefix.count).split(separator: "/").compactMap { Int($0) }
            if counts.count == 2, counts[1] > 0 { return UpscaleProgress(total: counts[1], ready: counts[0]) }
        }
        return nil
    }

    /// The reasons the log gives for inputs that produced no result, by the uploaded file name.
    static func failures(log: String) -> [String: String] {
        let prefix = "[upscale] failed "
        var reasons: [String: String] = [:]
        for line in log.split(separator: "\n") where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            guard let colon = rest.firstIndex(of: ":") else { continue }
            reasons[String(rest[..<colon])] = rest[rest.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return reasons
    }
}

/// One sample to upscale: its id in the project and the file the Mac sends.
struct UpscaleInput: Equatable {
    let sampleID: String
    let file: URL
}

/// What came back: the downloaded result of each sample that has one, and why the others have none.
struct UpscaleOutcome: Equatable {
    var results: [String: URL] = [:]
    var failures: [String: String] = [:]
}

extension GPUWorkspace {
    /// Why upscaling cannot start on this cloud GPU now, or nil when it can.
    var upscaleUnavailableReason: String? {
        if demoMode { return "The demo has no cloud GPU to upscale on. Open a project and rent one." }
        if !hasRunningPod || agent == nil {
            return "Upscaling runs on a cloud GPU. Rent one on the Cloud GPU screen, then come back here."
        }
        if isTraining { return "The cloud GPU is training. Upscale after the run finishes." }
        if isBusy || isStopping { return "The cloud GPU is busy with another action. Try again when it finishes." }
        return nil
    }

    /// The cloud GPU's price per hour, for the sentence beside the Upscale button.
    var upscaleHourlyRate: Double? {
        let rate = saved?.hourlyRate ?? pod?.cost ?? 0
        return rate > 0 ? rate : nil
    }

    /// Uploads `inputs` under neutral names, runs `upscale-media` on one GPU and downloads each result into
    /// `folder`, checked against the SHA-256 the agent lists. The cloud GPU counts as busy throughout, so the
    /// idle stop waits and the Cloud GPU screen starts nothing else.
    func upscale(
        _ inputs: [UpscaleInput], model: UpscaleModel, target: UpscaleTarget, into folder: URL,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> UpscaleOutcome {
        if let reason = upscaleUnavailableReason { throw StudioError.message(reason) }
        guard let agent, !inputs.isEmpty else { return UpscaleOutcome() }
        isBusy = true
        beginAppWork()
        defer {
            isBusy = false
            endAppWork()
        }
        let runID = "upscale-" + UUID().uuidString.prefix(12).lowercased()
        var names: [String: String] = [:] // uploaded stem -> sample id
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let stem = String(format: "u%04d", index + 1)
            let fileName = stem + "." + input.file.pathExtension.lowercased()
            let size = try Int64(input.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            progress("Sending \(input.sampleID) to the cloud GPU (\(index + 1) of \(inputs.count)).")
            try await agent.upload(name: runID, fileName: fileName, from: input.file, size: size)
            names[stem] = input.sampleID
        }
        let plan = try await agent.plan()
        try await prepareCaptionServerForTraining(agent, plan: plan) // a one-GPU computer frees its GPU first
        try await agent.start("upscale-media", gpus: [plan.train?.gpus.first ?? 0], params: [
            "run_id": .string(runID), "upload": .string(runID), "model": .string(model.rawValue),
            "resolution": .int(target.shortSide), "max_resolution": .int(target.longSideLimit),
        ])
        progress("Upscaling on the cloud GPU. The first use downloads the model to its storage.")
        do {
            try await waitForService("upscale-media") {
                guard let log = try? await agent.runLog(runID: runID),
                      let state = UpscaleProgress.parse(log: log) else { return }
                progress(state.text)
            }
        } catch is CancellationError {
            try? await agent.stop("upscale-media") // a cancelled upscale does not keep the GPU working
            throw CancellationError()
        }
        let log = await (try? agent.runLog(runID: runID)) ?? ""
        let files = try await agent.runFiles(runID: runID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var outcome = UpscaleOutcome()
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            guard let sampleID = names[Sources.stem(of: file.path)], !file.path.contains("/"),
                  ["png", "mp4"].contains(URL(fileURLWithPath: file.path).pathExtension) else { continue }
            progress("Downloading upscaled media \(index + 1) of \(files.count).")
            try await download(file, runID: runID, into: folder, agent: agent)
            outcome.results[sampleID] = folder.appendingPathComponent(file.path)
        }
        let reasons = UpscaleProgress.failures(log: log)
        for (stem, sampleID) in names where outcome.results[sampleID] == nil {
            let uploaded = reasons.first { Sources.stem(of: $0.key) == stem }
            outcome.failures[sampleID] = uploaded?.value ?? "no result came back; read the log of run \(runID)"
        }
        return outcome
    }
}
