import Foundation

/// Where the caption server is in its startup, read from the milestones vLLM logs, so the app can say it plainly
/// instead of showing log lines. Stages only move forward: the log tail the agent returns can scroll a milestone out.
enum CaptionStartupStage: Int, Comparable {
    case starting, downloading, loading, preparing, almostReady

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String {
        switch self {
        case .starting: "Starting the caption model…"
        case .downloading: "Downloading the caption model. The first start on a new cloud GPU takes a few minutes."
        case .loading: "Loading the caption model onto the GPU…"
        case .preparing: "Preparing the GPU for fast captioning…"
        case .almostReady: "Almost ready…"
        }
    }

    /// The furthest stage `log` shows, or `.starting` when it shows none.
    static func latest(in log: String) -> Self {
        log.split(whereSeparator: \.isNewline).map { stage(of: $0.lowercased()) }.max() ?? .starting
    }

    private static func stage(of line: String) -> Self {
        // The engine's opening lines print its whole configuration, which names later stages' settings.
        if line.contains("config:") || line.contains("non-default args") { return .starting }
        let milestones: [(Self, [String])] = [
            (.almostReady, [
                "available kv cache memory", "gpu kv cache size", "memory profiling", "capturing cuda graph",
                "init engine", "starting vllm api server", "application startup complete",
            ]),
            (.preparing, ["model loading took", "torch.compile", "custom fusions", "compiling a graph", "dynamo"]),
            (.loading, ["starting to load model", "loading safetensors", "loading weights took", "checkpoint shards"]),
            (.downloading, ["downloading", "fetching"]),
        ]
        return milestones.first { _, markers in markers.contains { line.contains($0) } }?.0 ?? .starting
    }
}
