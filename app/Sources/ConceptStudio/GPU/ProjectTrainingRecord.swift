import Foundation

/// The app-only training file inside a project folder, `<project>/.conceptstudio/training.json`:
/// the project's training results only. It is never published and is not part of job.yaml. The
/// output repo and its privacy live in the project's app state (`ProjectAppState.trainingOutput`),
/// which the session passes to `train(output:)`; each run keeps the destination it started with.
struct ProjectTrainingRecord: Codable, Equatable {
    var results: [TrainingResult] = []
    var runs: [TrainingRun] = []
    var comparisons: [GeneratedComparison] = []
    var reportGroups: [TrainingReportGroup] = []
    var reports: [TrainingReport] = []
    var selectedReportGroupID: String?

    init(results: [TrainingResult] = []) {
        self.results = results
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        results = try (values.decodeIfPresent([TrainingResult].self, forKey: .results) ?? [])
            .filter { RunArtifacts.validRunID($0.runID) }
        runs = try (values.decodeIfPresent([TrainingRun].self, forKey: .runs) ?? [])
            .filter { RunArtifacts.validRunID($0.runID) }
        comparisons = try (values.decodeIfPresent([GeneratedComparison].self, forKey: .comparisons) ?? [])
            .filter { RunArtifacts.validRunID($0.runID) && RunArtifacts.validRunID($0.sourceRunID) }
        reportGroups = try (values.decodeIfPresent([TrainingReportGroup].self, forKey: .reportGroups) ?? [])
            .filter { UUID(uuidString: $0.id) != nil }
        reports = try values.decodeIfPresent([TrainingReport].self, forKey: .reports) ?? []
        selectedReportGroupID = try values.decodeIfPresent(String.self, forKey: .selectedReportGroupID)
    }

    static func url(in project: URL) -> URL {
        project.appendingPathComponent(".conceptstudio/training.json")
    }

    static func load(from project: URL) -> ProjectTrainingRecord {
        guard let data = try? Data(contentsOf: url(in: project)), var record = try? JSONDecoder().decode(
            Self.self,
            from: data
        ) else { return ProjectTrainingRecord() }
        func confined(_ folder: String, runID: String) -> Bool {
            let expected = project.resolvingSymlinksInPath().appendingPathComponent("results/\(runID)")
            let actual = URL(fileURLWithPath: folder).standardizedFileURL
            return actual.resolvingSymlinksInPath().path == expected.path
        }
        func checked(_ result: TrainingResult) -> TrainingResult {
            var result = result
            if case let .saved(folder) = result.state, !confined(folder, runID: result.runID) {
                result.state = .pending
            }
            return result
        }
        record.results = record.results.map(checked)
        for index in record.runs.indices {
            if let folder = record.runs[index].localFolder, !confined(folder, runID: record.runs[index].runID) {
                record.runs[index].localFolder = nil
            }
            record.runs[index].result = record.runs[index].result.map(checked)
        }
        for index in record.comparisons.indices {
            if let folder = record.comparisons[index].folder,
               !confined(folder, runID: record.comparisons[index].runID) {
                record.comparisons[index].folder = nil
                if record.comparisons[index].state == .saved { record.comparisons[index].state = .pending }
            }
        }
        return record
    }

    func save(to project: URL) throws {
        let url = Self.url(in: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
