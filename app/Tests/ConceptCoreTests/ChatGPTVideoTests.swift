@testable import ConceptCore
import Foundation
import Synchronization
import Testing

@Suite("ChatGPT clip preparation")
struct ChatGPTVideoTests {
    private let video = UserContent.video(data: Data([3, 4]), mediaType: "video/mp4")

    @Test func orderedClipReplacementPreservesImagesTextAndAssistantTurns() async throws {
        let prepared = Mutex<[Data]>([])
        let wire = ChatGPTStreamWire { _ in ChatGPTWire.response(ChatGPTWire.event(ChatGPTWire.completed())) }
        let client = ChatGPTModelClient(
            model: "gpt-fixture", accessToken: { "fixture-oauth" },
            prepareVideo: { data, type in
                #expect(type == "video/mp4")
                prepared.withLock { $0.append(data) }
                return [.text("Ordered frames; audio unavailable."), .image(data: data, mediaType: "image/jpeg")]
            }, transport: wire
        )
        let reply = try await client.request(
            instructions: "Keep the H3 video profile.",
            messages: [
                .user([.text("Before"), .image(data: Data([1]), mediaType: "image/png"), video, .text("After")]),
                .assistant("First caption"), .user([.text("Review this clip"), video]),
            ],
            output: ChatGPTWire.output, settings: RequestSettings()
        )
        #expect(reply.text == ChatGPTWire.caption)
        #expect(prepared.withLock { $0 } == [Data([3, 4]), Data([3, 4])])
        let request = try #require(await wire.requests.first)
        let body = try JSONValue(parsing: #require(request.httpBody))
        let input = try #require(body.field("input")?.arrayValue)
        #expect(body.field("instructions") == .string("Keep the H3 video profile."))
        let first = try #require(input[0].field("content")?.arrayValue)
        #expect(first.map { $0.field("type")?.stringValue } == [
            "input_text", "input_image", "input_text", "input_image", "input_text",
        ])
        #expect(first[0].field("text") == .string("Before"))
        #expect(first[1].field("image_url") == .string("data:image/png;base64,AQ=="))
        #expect(first[2].field("text") == .string("Ordered frames; audio unavailable."))
        #expect(first[3].field("image_url") == .string("data:image/jpeg;base64,AwQ="))
        #expect(first[4].field("text") == .string("After"))
        #expect(input[1] == .object(["role": .string("assistant"), "content": .string("First caption")]))
        #expect(input[2].field("content")?.element(0)?.field("text") == .string("Review this clip"))
        #expect(await wire.requests.count == 1)
    }

    @Test(arguments: ["model", "settings", "tool", "cancelled"])
    func inadmissibleRequestDoesNotPrepareClipOrReadToken(reason: String) async {
        let reads = Mutex(0)
        let wire = ChatGPTStreamWire { _ in
            Issue.record("Rejected clip reached transport"); return ChatGPTWire.response([])
        }
        let client = ChatGPTModelClient(
            model: reason == "model" ? " " : "fixture", accessToken: { reads.withLock { $0 += 1 }; return "token" },
            prepareVideo: { _, _ in Issue.record("Invalid request prepared media"); return [] }, transport: wire
        )
        let task = Task {
            if reason == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
            return try await client.request(
                instructions: "Caption", messages: [.user([video])],
                output: OutputRequest(
                    name: "Caption",
                    schema: Caption.jsonSchema,
                    mode: reason == "tool" ? .tool : .native
                ),
                settings: reason == "settings" ? RequestSettings(temperature: 0.2) : RequestSettings()
            )
        }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(reads.withLock { $0 } == 0)
        #expect(await wire.requests.isEmpty)
    }

    @Test(arguments: [false, true])
    func preparationFailureOrCancellationNeverReadsToken(cancel: Bool) async {
        let reads = Mutex(0)
        let wire = ChatGPTStreamWire { _ in
            Issue.record("Rejected clip reached transport"); return ChatGPTWire.response([])
        }
        let client = ChatGPTModelClient(
            model: "fixture", accessToken: { reads.withLock { $0 += 1 }; return "token" },
            prepareVideo: { _, _ in
                if cancel {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return [.image(data: Data([1]), mediaType: "image/jpeg")]
                }
                throw ConfigurationError("Unreadable clip")
            }, transport: wire
        )
        let task = Task {
            try await client.request(
                instructions: "Caption", messages: [.user([video])], output: ChatGPTWire.output,
                settings: RequestSettings()
            )
        }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(reads.withLock { $0 } == 0)
        #expect(await wire.requests.isEmpty)
    }

    @Test func fullConvertedRequestLimitStillAppliesBeforeTokenAccess() async {
        let reads = Mutex(0)
        let wire = ChatGPTStreamWire { _ in
            Issue.record("Rejected clip reached transport"); return ChatGPTWire.response([])
        }
        let client = ChatGPTModelClient(
            model: "fixture", accessToken: { reads.withLock { $0 += 1 }; return "token" },
            prepareVideo: { _, _ in [.image(data: Data([1]), mediaType: "image/jpeg")] }, transport: wire
        )
        await #expect(throws: ConfigurationError.self) {
            try await client.request(
                instructions: String(repeating: "x", count: MediaInput.maximumVideoRequestBytes),
                messages: [.user([video])], output: ChatGPTWire.output, settings: RequestSettings()
            )
        }
        #expect(reads.withLock { $0 } == 0)
        #expect(await wire.requests.isEmpty)
    }

    @Test(arguments: ["h3-video", "ltx-video"])
    func runnerKeepsOriginalClipIDProfileAndBytes(profile: String) async throws {
        let directory = try Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([3, 4])
        let clip = directory.appendingPathComponent("clip.mp4")
        try bytes.write(to: clip)
        var job = try Fixtures.job()
        job.profile = profile
        job.samples = ["clip.mp4": Fixtures.soloMapping]
        let wire = ChatGPTStreamWire { request in
            let body = try JSONValue(parsing: #require(request.httpBody))
            #expect(body.field("instructions")?.stringValue?.contains("attached_target_video") == true)
            return ChatGPTWire.response(ChatGPTWire.event(ChatGPTWire.completed()))
        }
        let client = ChatGPTModelClient(
            model: "fixture", accessToken: { "fixture" },
            prepareVideo: { data, _ in
                #expect(data == bytes)
                return [.text("Ordered clip frames"), .image(data: Data([1]), mediaType: "image/jpeg")]
            }, transport: wire
        )
        let runner = try Runner(job: job, captioner: ResolvedEndpoint(client: client))
        let sink = try SidecarSink(directory: directory)
        let summary = try await runner.run(source: LocalFolderSource(directory: directory), sink: sink)
        #expect(summary.outcomes.map(\.status) == [.written])
        let record = try #require(try await sink.record("clip.mp4"))
        #expect(record.sampleID == "clip.mp4")
        #expect(record.profile == profile)
        #expect(try Data(contentsOf: clip) == bytes)
        #expect(try String(contentsOf: sink.captionURL(for: "clip.mp4"), encoding: .utf8).contains("NORA7"))
    }
}
