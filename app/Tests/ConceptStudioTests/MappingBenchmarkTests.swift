import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

/// Opt-in real inference. Input is a PRIVATE COPY of a confirmed project; never changes mappings.
/// Run only with the owner's explicit provider/data authorization. No private sample names are logged.
@Suite("mapping benchmark", .serialized)
@MainActor
struct MappingBenchmarkTests {
    @Test func confirmedDatasetLayouts() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MAPPING_BENCHMARK_PROJECT"], let output = env["MAPPING_BENCHMARK_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath: path)
        let savedJob = try Data(contentsOf: directory.appendingPathComponent("job.yaml"))
        let project = try await StudioProject.open(at: directory)
        let concepts = project.job.concepts.filter(\.targetConcept.requiresLocator)
        let images = project.images
            .filter { !Sources.isVideo(Sources.suffix(of: $0.id)) && project.job.mapping(for: $0.id) != nil }
            .filter {
                env["MAPPING_BENCHMARK_MULTI_PERSON_ONLY"] != "1" || (project.job.mapping(for: $0.id)?.count ?? 0) > 1
            }
        #expect(!images.isEmpty)
        let references = Dictionary(uniqueKeysWithValues: concepts.map { (
            $0.trigger,
            project.referenceURL(for: $0.trigger)
        ) })
        let endpoint = try await benchmarkEndpoint(env)
        let assistant = StudioAssistant(endpoint: endpoint, demo: false)
        let allowed = Set(concepts.map(\.trigger))
        var rows: [BenchmarkRow] = []
        var details: [BenchmarkDetail] = []
        for size in [1, 4, 9] {
            var correct = 0, truePositive = 0, falsePositive = 0, falseNegative = 0, failed = 0
            let batches = MappingRequests.batches(images, size: size)
            let start = Date()
            for batch in batches {
                try Task.checkCancellation()
                let result = await assistant.mappingResult(images: batch, references: references, concepts: concepts)
                failed += result.failures.count
                for image in batch {
                    let truth = Set(project.job.mapping(for: image.id)?.keys ?? []).intersection(allowed)
                    let prediction = Set(result.suggestions[image.id]?.mapping.keys ?? []).intersection(allowed)
                    if result.suggestions[image.id] != nil, truth == prediction { correct += 1 }
                    truePositive += truth.intersection(prediction).count
                    falsePositive += prediction.subtracting(truth).count
                    falseNegative += truth.subtracting(prediction).count
                    details.append(BenchmarkDetail(
                        layout: size, ordinal: images.firstIndex { $0.id == image.id } ?? 0,
                        truth: Dictionary(uniqueKeysWithValues: (project.job.mapping(for: image.id) ?? [:]).map {
                            ($0.key, $0.value)
                        }),
                        prediction: Dictionary(uniqueKeysWithValues: (result.suggestions[image.id]?.mapping ?? [:])
                            .map {
                                ($0.key, $0.value)
                            }),
                        description: result.suggestions[image.id]?.description ?? "Failed"
                    ))
                }
                if let privatePath = env["MAPPING_BENCHMARK_DETAILS"] {
                    try JSONEncoder().encode(details).write(to: URL(fileURLWithPath: privatePath), options: .atomic)
                }
                print(
                    "Mapping benchmark layout \(size): "
                        + "processed \(details.filter { $0.layout == size }.count)/\(images.count)"
                )
            }
            let row = BenchmarkRow(
                layout: size,
                samples: images.count,
                plannedBatches: batches.count,
                elapsedSeconds: Date().timeIntervalSince(start),
                exactPresenceMatches: correct,
                truePositive: truePositive,
                falsePositive: falsePositive,
                falseNegative: falseNegative,
                failed: failed,
                model: endpoint.requested
            )
            rows.append(row)
            // Aggregate-only receipt: never filenames, names, captions, images or model descriptions.
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: output), options: .atomic)
            print(
                "Mapping benchmark layout \(size): \(correct)/\(images.count) exact concept-presence matches; "
                    + "\(failed) failures; \(Int(row.elapsedSeconds)) seconds"
            )
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("job.yaml")) == savedJob)
    }

    private func benchmarkEndpoint(_ env: [String: String]) async throws -> ResolvedEndpoint {
        let endpoint: ResolvedEndpoint
        if let configPath = env["MAPPING_BENCHMARK_ENDPOINT"] {
            let config = try JSONDecoder().decode(
                BenchmarkEndpoint.self,
                from: Data(contentsOf: URL(fileURLWithPath: configPath))
            )
            endpoint = try Endpoints.resolve(
                EndpointSpec(kind: "vllm", model: config.model, baseURL: config.baseURL, outputMode: .native),
                keys: StaticKeyStore([.vllm: config.token], vllmBaseURL: config.baseURL)
            )
        } else {
            let session = StudioSession()
            await session.chatGPT.load()
            await session.chatGPT.refreshModels()
            session.openAIUsesChatGPT = true
            let model = try #require(
                env["MAPPING_BENCHMARK_MODEL"] ?? session.chatGPT.availableModels.first?.slug,
                "Sign in with ChatGPT and allow plan usage in the app before this benchmark."
            )
            endpoint = try session.endpoint(model: model, kind: "openai")
        }
        return endpoint
    }
}

private struct BenchmarkEndpoint: Decodable {
    let baseURL: String
    let model: String
    let token: String
}

private struct BenchmarkRow: Codable {
    let layout: Int
    let samples: Int
    let plannedBatches: Int
    let elapsedSeconds: Double
    let exactPresenceMatches: Int
    let truePositive: Int
    let falsePositive: Int
    let falseNegative: Int
    let failed: Int
    let model: String
}

/// Written only to the explicit private audit path, never to the aggregate receipt or test logs.
private struct BenchmarkDetail: Codable {
    let layout: Int
    let ordinal: Int
    let truth: [String: String]
    let prediction: [String: String]
    let description: String
}
