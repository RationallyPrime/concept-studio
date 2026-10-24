@testable import ConceptStudio
import Testing

@Suite("Caption server startup stage")
struct CaptionStartupStageTests {
    @Test func vLLMStartupReadsAsPlainStages() {
        let tails: [(String, CaptionStartupStage)] = [
            (
                "(APIServer pid=2416) INFO 10-23 23:51:02 [utils.py:253] non-default args: {'model': 'm', "
                    + "'enforce_eager': True, 'gpu_memory_utilization': 0.85}",
                .starting
            ),
            (
                "(EngineCore pid=2490) INFO 10-23 23:51:09 [core.py:93] Initializing a V1 LLM engine with config: "
                    + "model='m', kv_cache_dtype=auto, compilation_config={'level': 3}",
                .starting
            ),
            (
                "(EngineCore pid=2490) INFO 10-23 23:51:14 [weight_utils.py:390] Downloading weights from HF",
                .downloading
            ),
            ("Loading safetensors checkpoint shards:  40% Completed | 2/5", .loading),
            (
                "(APIServer pid=2416) INFO 10-23 23:55:33 [compilation.py:331] Enabled custom fusions: norm_quant, "
                    + "act_quant",
                .preparing
            ),
            (
                "(EngineCore pid=2490) INFO 10-23 23:55:41 [gpu_worker.py:298] Available KV cache memory: 4.1 GiB",
                .almostReady
            ),
        ]
        for (tail, expected) in tails {
            #expect(CaptionStartupStage.latest(in: tail) == expected, "\(tail)")
        }
        #expect(CaptionStartupStage.latest(in: "") == .starting)
        #expect(CaptionStartupStage.latest(in: tails.map(\.0).joined(separator: "\n")) == .almostReady)
    }
}
