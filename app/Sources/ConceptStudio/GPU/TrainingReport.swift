import ConceptCore
import Foundation

struct ReportPrompt: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case concept, bleed }
    let id: String
    let trigger: String
    let category: TargetConcept
    let kind: Kind
    var text: String
    /// Attributes selected because the saved captions do not mention them.
    var heldOutAttributes: [String]
}

struct ReportReference: Codable, Equatable {
    let trigger: String
    let category: TargetConcept
    /// Basenames inside this comparison group's private project folder.
    let files: [String]
    let sha256: [String]
}

struct ReportRenderSettings: Codable, Equatable {
    let trainer: String
    let baseModel: String
    let resolution: Int
    let inferenceSteps: Int
    let guidanceScale: Double
    let frames: Int
    let frameRate: Int
    let judgeModel: String
    let judgeExtraBodyJSON: Data

    var judgeRequestSettings: RequestSettings {
        var extraBody = (try? JSONValue(parsing: judgeExtraBodyJSON).objectValue) ?? [:]
        // These two settings define the comparison group even if the captioner's body overrides them.
        extraBody["temperature"] = nil
        extraBody["seed"] = nil
        return RequestSettings(temperature: 0, seed: 42, extraBody: extraBody)
    }
}

struct TrainingReportGroup: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var prompts: [ReportPrompt]
    let seeds: [Int]
    let settings: ReportRenderSettings
    let captionDigest: String
    let manualPrompts: Bool
    var references: [ReportReference] = []
    var frozenAt: Date?
    let createdAt: Date

    var needsPrompts: Bool {
        prompts.isEmpty || prompts.contains { $0.text.isBlank }
    }

    func folder(in project: URL) -> URL {
        ProjectAppState.folder(in: project).appendingPathComponent("report-groups/" + id)
    }

    func edited(prompts: [ReportPrompt]) -> TrainingReportGroup {
        guard frozenAt != nil else {
            var draft = self
            draft.prompts = prompts
            return draft
        }
        return TrainingReportGroup(
            id: UUID().uuidString.lowercased(), name: name, prompts: prompts, seeds: seeds,
            settings: settings, captionDigest: captionDigest, manualPrompts: manualPrompts, createdAt: Date()
        )
    }
}

struct ReportMetric: Codable, Equatable {
    let base: Double?
    let lora: Double?
    let note: String?
}

struct ReportSample: Codable, Equatable, Identifiable {
    var id: String {
        comparisonID + ":" + promptID + ":" + String(seed)
    }

    let comparisonID: String
    let promptID: String
    let seed: Int
    let basePath: String
    let loraPath: String
    var identity: ReportMetric?
    var style: ReportMetric?
    var adherence: ReportMetric?
}

struct TrainingReport: Codable, Equatable, Identifiable {
    enum State: String, Codable { case waiting, running, complete, failed }
    var id: String {
        runID
    }

    let runID: String
    let groupID: String
    var state: State = .waiting
    var samples: [ReportSample] = []
    var completedPromptIDs: [String] = []
    var failure: String?
    var completedAt: Date?

    /// Missing faces or failed judges stay missing. Coverage travels beside every mean.
    func mean(_ metric: (ReportSample) -> ReportMetric?) -> (value: Double?, count: Int) {
        let values = samples.compactMap { metric($0)?.lora }
        return (values.isEmpty ? nil : values.reduce(0, +) / Double(values.count), values.count)
    }
}

enum ReportPrompts {
    private struct Attribute {
        let phrase: String
        let words: [String]
    }

    private static let settings = [
        Attribute(phrase: "in a snowy garden", words: ["snow", "winter"]),
        Attribute(phrase: "inside a quiet library", words: ["library", "bookshelf", "bookshelves"]),
        Attribute(phrase: "beside a harbour at sunrise", words: ["harbour", "harbor", "sunrise"]),
        Attribute(phrase: "under a stone archway", words: ["archway", "arch"]),
        Attribute(phrase: "in a greenhouse", words: ["greenhouse"]),
    ]
    private static let outfits = [
        Attribute(phrase: "wearing a yellow raincoat", words: ["raincoat", "rain coat"]),
        Attribute(phrase: "wearing a formal navy suit", words: ["suit", "formal"]),
        Attribute(phrase: "wearing a green knitted sweater", words: ["sweater", "jumper", "knit"]),
        Attribute(phrase: "wearing a red winter coat", words: ["winter coat", "overcoat"]),
    ]
    private static let poses = [
        Attribute(phrase: "holding a ceramic cup", words: ["cup", "mug"]),
        Attribute(phrase: "sitting on a wooden bench", words: ["bench"]),
        Attribute(phrase: "reading an open book", words: ["reading", "book"]),
        Attribute(phrase: "holding an umbrella", words: ["umbrella"]),
    ]
    private static let subjects = [
        Attribute(phrase: "An ornate ceramic teapot", words: ["teapot", "tea pot"]),
        Attribute(phrase: "A suspension bridge over a river", words: ["bridge", "river"]),
        Attribute(phrase: "A bowl of oranges and lemons", words: ["orange", "lemon", "citrus"]),
        Attribute(phrase: "A bicycle beside a brick wall", words: ["bicycle", "bike"]),
        Attribute(phrase: "A lighthouse above the sea", words: ["lighthouse"]),
    ]

    static func draft(job: Job, captions: [String]) -> [ReportPrompt] {
        let corpus = captions.joined(separator: "\n").lowercased()
        func absent(_ choices: [Attribute]) -> Attribute? {
            choices.first { choice in !choice.words.contains { corpus.contains($0) } }
        }
        return job.concepts.flatMap { concept -> [ReportPrompt] in
            let selected: [Attribute?] = switch concept.targetConcept {
            case .facialIdentity, .fullIdentity, .characterDesign:
                [absent(outfits), absent(poses), absent(settings)]
            case .style: [absent(subjects)]
            case .object, .motion, .custom: [absent(settings)]
            }
            let attributes = selected.compactMap(\.self)
            let complete = attributes.count == selected.count && !job.adultContent
            let details = attributes.map(\.phrase).joined(separator: ", ")
            let text = if !complete { "" } else {
                switch concept.targetConcept {
                case .style: "\(details), in the visual style of \(concept.trigger)."
                case .object: "\(concept.trigger), clearly visible \(attributes[0].phrase)."
                case .motion: "A fully clothed performer demonstrating \(concept.trigger) \(attributes[0].phrase)."
                case .custom: "A scene showing \(concept.trigger) \(attributes[0].phrase)."
                default: "\(concept.trigger), \(details)."
                }
            }
            var prompts = [ReportPrompt(
                id: UUID().uuidString.lowercased(), trigger: concept.trigger, category: concept.targetConcept,
                kind: .concept, text: text, heldOutAttributes: complete ? attributes.map(\.phrase) : []
            )]
            if concept.targetConcept.isPersonIdentity {
                prompts.append(ReportPrompt(
                    id: UUID().uuidString.lowercased(), trigger: concept.trigger, category: concept.targetConcept,
                    kind: .bleed, text: text.replacingOccurrences(of: concept.trigger, with: "A " + concept.classNoun),
                    heldOutAttributes: complete ? attributes.map(\.phrase) : []
                ))
            }
            return prompts
        }
    }
}

struct SavedTrainingReport: Encodable {
    let group: TrainingReportGroup
    let report: TrainingReport
}
