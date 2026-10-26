import ConceptCore
import Foundation

/// The frozen adapter an H3 run trains on top of and leaves out at inference. Its names, files, defaults
/// and guidance rule come from the shared `h3-recipe-fields.json`, which the pod reads too.
enum H3TrainingAdapter: Hashable {
    /// Circlestone's for stills, Ostris's once clips are among the inputs (the policy's defaults).
    case automatic
    case named(String)
    case off

    struct Policy {
        /// Adapter name to its file name, in the policy's order.
        var files: [(name: String, file: String)] = []
        var imageDefault = "circlestone"
        var videoDefault = "circlestone"
        var refusingGuidanceLoss: Set<String> = []
    }

    static let policy: Policy = {
        guard let url = Bundle.module.url(
                  forResource: "h3-recipe-fields", withExtension: "json", subdirectory: "Training"
              ), let data = try? Data(contentsOf: url),
              let fields = try? JSONDecoder().decode([String: [String]].self, from: data) else { return Policy() }
        let prefix = "training_adapter."
        return Policy(
            files: fields.keys.filter { $0.hasPrefix(prefix) }.sorted().compactMap { key in
                fields[key]?.first.map { (String(key.dropFirst(prefix.count)), $0) }
            },
            imageDefault: fields["training_adapter_default.image"]?.first ?? "circlestone",
            videoDefault: fields["training_adapter_default.video"]?.first ?? "circlestone",
            refusingGuidanceLoss: Set(fields["training_adapter_refuses_guidance_loss"] ?? [])
        )
    }()

    /// The adapter saved settings trained with. Recipes from before the choice existed used Circlestone's.
    init(settings: JSONObject) {
        let model = settings["model"]?.objectValue ?? [:]
        if model["use_training_adapter"]?.boolValue == false {
            self = .off
        } else {
            self = .named(model["training_adapter"]?.stringValue ?? "circlestone")
        }
    }

    /// The pinned adapter a native recipe's `assistant_lora_path` names; nil when the file is not one of them.
    static func named(file path: String) -> H3TrainingAdapter? {
        let file = (path as NSString).lastPathComponent
        return policy.files.first { $0.file == file }.map { .named($0.name) }
    }

    func resolved(containsVideo: Bool) -> String? {
        switch self {
        case .automatic: containsVideo ? Self.policy.videoDefault : Self.policy.imageDefault
        case let .named(name): name
        case .off: nil
        }
    }

    func refusesGuidanceLoss(containsVideo: Bool) -> Bool {
        resolved(containsVideo: containsVideo).map(Self.policy.refusingGuidanceLoss.contains) ?? false
    }

    /// Writes the resolved choice into a run's `extra.model`, so a Repeat trains on the same adapter.
    func write(into extra: inout JSONObject, containsVideo: Bool) {
        var model = extra["model"]?.objectValue ?? [:]
        let name = resolved(containsVideo: containsVideo)
        model["use_training_adapter"] = .bool(name != nil)
        model["training_adapter"] = name.map(JSONValue.string)
        extra["model"] = .object(model)
    }

    static func label(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }
}
