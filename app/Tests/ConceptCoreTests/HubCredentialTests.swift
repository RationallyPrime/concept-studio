import ConceptCore
import Foundation
import Testing

@Suite("Hub credentials during transfers")
struct HubCredentialTests {
    @Test func refreshesAfterUploadsBeforeVerificationAndCommit() async throws {
        let credentials = TransferCredentials("initial")
        let first = Data([1, 2, 3]), second = Data([4, 5])
        let secondOID = Hub.sha256(second)
        let transport = StubTransport { request in
            switch Hub.route(request) {
            case Hub.preuploadRoute:
                return try Hub.preupload(request)
            case Hub.batchRoute:
                return try Self.verifiedBatch(request)
            case let route where route.hasPrefix("PUT /upload/"):
                let firstUpload = request.httpBody == first
                #expect(await credentials.calls == (firstUpload ? 2 : 3))
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                let oid = try #require(request.url?.lastPathComponent)
                #expect(request.value(forHTTPHeaderField: "x-upload-token") == "t-\(oid)")
                // The current access token expires while bytes travel to the signed storage URL.
                await credentials.replace(firstUpload ? "after-first-upload" : "after-second-upload")
                return HTTPResponse(status: 200)
            case let route where route.hasPrefix("POST /verify/"):
                if request.url?.lastPathComponent == secondOID {
                    await credentials.replace("before-commit")
                }
                return HTTPResponse(status: 200)
            case Hub.commitRoute:
                return try StubTransport.json(["commitOid": Hub.commitOID, "commitUrl": Hub.commitURL])
            default:
                return HTTPResponse(status: 404)
            }
        }
        let client = HubClient(tokenProvider: { try await credentials.resolve() }, transport: transport)
        let result = try await client.commit(
            repo: RepoID(Hub.repo),
            operations: [.add(path: "a.png", data: first), .add(path: "b.png", data: second)],
            message: "Two files across credential refreshes"
        )
        #expect(result.commitOID == Hub.commitOID)
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "PUT", "POST", "PUT", "POST", "POST"])
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
            "Bearer initial", "Bearer initial", nil, "Bearer after-first-upload", nil,
            "Bearer after-second-upload", "Bearer before-commit",
        ])
        #expect(await credentials.calls == 5)
        let lines = try Hub.commitLines(#require(requests.last))
        #expect(lines.map(\.key) == ["header", "lfsFile", "lfsFile"])
        #expect(lines.dropFirst().map { $0.value["path"] as? String } == ["a.png", "b.png"])
    }

    @Test(arguments: [false, true])
    func refreshFailureStopsBeforeTheNextAuthenticatedPhase(beforeCommit: Bool) async throws {
        let credentials = TransferCredentials("initial")
        let transport = StubTransport { request in
            switch Hub.route(request) {
            case Hub.preuploadRoute:
                return try Hub.preupload(request)
            case Hub.batchRoute:
                return try Self.verifiedBatch(request)
            case let route where route.hasPrefix("PUT /upload/"):
                #expect(await credentials.calls == 2)
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                if !beforeCommit { await credentials.expire() }
                return HTTPResponse(status: 200)
            case let route where route.hasPrefix("POST /verify/"):
                #expect(beforeCommit)
                await credentials.expire()
                return HTTPResponse(status: 200)
            default:
                Issue.record("A request escaped the failed credential refresh: \(Hub.route(request))")
                return HTTPResponse(status: 500)
            }
        }
        let client = HubClient(tokenProvider: { try await credentials.resolve() }, transport: transport)
        await #expect(throws: TransferCredentialError.expired) {
            try await client.uploadFile(
                repo: RepoID(Hub.repo), path: "a.png", data: Data([1, 2, 3]), message: "No stale-token fallback"
            )
        }
        let requests = await transport.requests
        #expect(requests.count == (beforeCommit ? 4 : 3))
        #expect(await credentials.calls == (beforeCommit ? 4 : 3))
        #expect(!requests.contains { Hub.route($0) == Hub.commitRoute })
        #expect(requests.last?.httpMethod == (beforeCommit ? "POST" : "PUT"))
    }

    @Test func offHostNextPageDoesNotResolveOrReceiveHubCredentials() async throws {
        let credentials = TransferCredentials("initial")
        let next = "https://listing.test/next?page=2"
        let transport = StubTransport { request in
            if request.url?.host() == "huggingface.co" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer initial")
                await credentials.expire()
                return try StubTransport.json(
                    [Hub.file("a.png", size: 1, lfs: false)], headers: ["link": "<\(next)>; rel=\"next\""]
                )
            }
            #expect(request.url?.absoluteString == next)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return try StubTransport.json([Hub.file("b.png", size: 2, lfs: false)])
        }
        let client = HubClient(tokenProvider: { try await credentials.resolve() }, transport: transport)
        let files = try await client.listFiles(repo: RepoID(Hub.repo))
        #expect(files.map(\.path) == ["a.png", "b.png"])
        #expect(await transport.requests.count == 2)
        #expect(await credentials.calls == 1)
    }

    @Test func disconnectedProviderAllowsAnonymousPublicReads() async throws {
        let credentials = TransferCredentials(nil)
        let bytes = Data("public media".utf8)
        let transport = StubTransport { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            if Hub.route(request) == Hub.treeRoute {
                return try StubTransport.json([Hub.file("a.png", size: bytes.count, lfs: false)])
            }
            return HTTPResponse(status: 200, body: bytes)
        }
        let client = HubClient(tokenProvider: { try await credentials.resolve() }, transport: transport)
        let files = try await client.listFiles(repo: RepoID(Hub.repo))
        let downloaded = try await client.download(repo: RepoID(Hub.repo), path: "a.png")
        #expect(files.map(\.path) == ["a.png"])
        #expect(downloaded == bytes)
        #expect(await credentials.calls == 2)
    }

    private static func verifiedBatch(_ request: URLRequest) throws -> HTTPResponse {
        let reply = try Hub.batch(request)
        var body = try #require(JSONSerialization.jsonObject(with: reply.body) as? [String: Any])
        body["objects"] = try #require(body["objects"] as? [[String: Any]]).map { original in
            var object = original
            let oid = try #require(object["oid"] as? String)
            var actions = try #require(object["actions"] as? [String: Any])
            actions["verify"] = ["href": "https://huggingface.co/verify/\(oid)"]
            object["actions"] = actions
            return object
        }
        return try StubTransport.json(body)
    }
}

private enum TransferCredentialError: Error, Equatable {
    case expired
}

private actor TransferCredentials {
    var token: String?
    var expired = false
    private(set) var calls = 0

    init(_ token: String?) {
        self.token = token
    }

    func replace(_ token: String) {
        self.token = token
    }

    func expire() {
        expired = true
    }

    func resolve() throws -> String? {
        calls += 1
        if expired { throw TransferCredentialError.expired }
        return token
    }
}
