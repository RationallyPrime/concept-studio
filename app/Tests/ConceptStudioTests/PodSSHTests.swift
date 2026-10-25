import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Pod SSH access")
struct PodSSHTests {
    /// A synthetic Ed25519 key blob: type header, key length and 32 test bytes.
    private var publicKey: String {
        let type = Array("ssh-ed25519".utf8)
        let data = Data([0, 0, 0, UInt8(type.count)] + type + [0, 0, 0, 32] + [UInt8](repeating: 7, count: 32))
        return "ssh-ed25519 " + data.base64EncodedString() + " test-only"
    }

    @Test func validatesPublicKeysAndRefusesPrivateMaterial() throws {
        #expect(try PodSSH.publicKey(" \n" + publicKey + "\n") == publicKey)
        #expect(try PodSSH.publicKey("  ") == "")
        #expect(throws: (any Error).self) { try PodSSH.publicKey("-----BEGIN OPENSSH PRIVATE KEY-----") }
        #expect(throws: (any Error).self) { try PodSSH.publicKey("ssh-ed25519 invalid") }
    }

    @MainActor @Test func settingsKeepThePublicKeyAcrossRelaunch() {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults)
        session.sshPublicKey = publicKey
        session.rememberChoices()
        let reopened = StudioSession(preferences: defaults.defaults)
        #expect(reopened.sshPublicKey == publicKey)
    }

    @MainActor @Test(arguments: [false, true])
    func rentalsExposeSSHAndOnlySendAConfiguredPublicKey(enabled: Bool) async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let transport = UnreachableAgentTransport(agentAvailable: true, inferenceReady: true)
        let workspace = makeWorkspace(transport, defaults.defaults)
        try workspace.configure(
            runpodKey: "fixture-provider", hubToken: "fixture-hub", imageName: "fixture/image",
            sshPublicKey: enabled ? publicKey : ""
        )
        await workspace.refreshOffers()
        await workspace.rent()
        #expect(workspace.failure == nil)
        let body = try #require(await transport.createBodies.first)
        #expect(body["ports"]?.arrayValue?.compactMap(\.stringValue) == ["8800/http", "8000/http", "22/tcp"])
        #expect(body["env"]?.objectValue?["PUBLIC_KEY"]?.stringValue == (enabled ? publicKey : nil))
        await workspace.stopEverything()
    }
}
