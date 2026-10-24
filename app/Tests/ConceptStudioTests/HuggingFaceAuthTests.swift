import ConceptCore
@testable import ConceptStudio
import CryptoKit
import Foundation
import Testing

@Suite("Hugging Face account ownership")
@MainActor
struct HuggingFaceAuthTests {
    @Test func initializationIsIdleAndDisconnectedPublicReadsReturnNil() async throws {
        let store = HuggingFaceTestSecrets(), fixture = HuggingFaceAuthFixture()
        let connection = huggingFaceTestConnection(store, fixture)
        #expect(store.reads.isEmpty)
        #expect(await fixture.requests.isEmpty)
        #expect(try await connection.optionalAccessToken() == nil)
        await #expect(throws: HuggingFaceAuthError.self) { try await connection.accessToken() }
    }

    @Test func publicPKCESignInStoresOneOAuthRecordAndFixedEndpointIdentity() async throws {
        let store = HuggingFaceTestSecrets(["huggingface": "existing-manual"]), fixture = HuggingFaceAuthFixture()
        let connection = huggingFaceTestConnection(store, fixture)
        #expect(await connection.signIn())
        #expect(connection.isConnected && connection.usesOAuth)
        #expect(connection.username == "fixture-user")
        #expect(store.values["huggingface"] == "existing-manual")
        let encoded = try #require(store.values[HuggingFaceSession.oauthAccount])
        let saved = try JSONDecoder().decode(HuggingFaceOAuthRecord.self, from: Data(encoded.utf8))
        #expect(saved.tokens?.accessToken == "fresh-access")
        #expect(saved.tokens?.refreshToken == "fresh-refresh")
        #expect(saved.tokens?.expiresAt == huggingFaceTestNow.addingTimeInterval(3600))
        let browser = try #require(await fixture.browserURLs.first)
        let query = try Dictionary(uniqueKeysWithValues: #require(URLComponents(
            url: browser,
            resolvingAgainstBaseURL: false
        )?
            .queryItems?.map { ($0.name, $0.value!) }))
        #expect(query["client_id"] == "fixture-public-client")
        #expect(try Set(#require(query["scope"]?.split(separator: " ").map(String.init))) ==
            Set(HuggingFaceAuthorization.scopes))
        #expect(query["code_challenge_method"] == "S256")
        let request = try #require(await fixture.requests.first)
        let fields = Self.fields(request)
        #expect(fields["client_secret"] == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(fields["redirect_uri"] == "http://127.0.0.1:14555/auth/callback")
        #expect(try query["code_challenge"] == ChatGPTAuth
            .encode(Data(SHA256.hash(data: Data(#require(fields["code_verifier"]?.utf8))))))
        #expect(await fixture.requests.last?.url == HuggingFaceAuthorization.userInfoURL)
        #expect(await fixture.callbackCancelled)
    }

    @Test(arguments: ["denied", "state", "scopes", "redirect", "profile"])
    func failedSignInPreservesOldManualCredential(reason: String) async throws {
        let store = HuggingFaceTestSecrets(["huggingface": "existing-manual"]), fixture = HuggingFaceAuthFixture()
        await fixture.configure(
            tokenStatus: reason == "redirect" ? 302 : 200,
            scope: reason == "scopes" ? "openid profile" : nil,
            deny: reason == "denied", badState: reason == "state", profileStatus: reason == "profile" ? 401 : 200
        )
        let connection = huggingFaceTestConnection(store, fixture)
        #expect(await !connection.signIn())
        #expect(store.values == ["huggingface": "existing-manual"])
        #expect(try await connection.accessToken() == "existing-manual")
        #expect(await fixture.callbackCancelled)
        if reason == "denied" || reason == "state" { #expect(await fixture.requests.isEmpty) }
    }

    @Test(arguments: ["", "{broken", "expired"])
    func storedOAuthAlwaysWinsBeforeMetadataLoads(record: String) async throws {
        let saved = try record == "expired" ? huggingFaceSavedRecord(expired: true, refreshToken: nil) : record
        let store = HuggingFaceTestSecrets(["huggingface": "stale-manual", HuggingFaceSession.oauthAccount: saved])
        let fixture = HuggingFaceAuthFixture()
        let connection = huggingFaceTestConnection(store, fixture)
        let configuration = try connection.storedTokenConfiguration()
        #expect(configuration.manualToken.isEmpty)
        #expect(configuration.oauthToken != nil)
        #expect(!store.reads.contains("huggingface"))
        await #expect(throws: HuggingFaceAuthError.self) { try #require(try await configuration.oauthToken?()) }
        #expect(await fixture.requests.isEmpty)
        #expect(store.values["huggingface"] == "stale-manual")
    }

    @Test func manualConfigurationIsSynchronousAndDoesNotRefresh() throws {
        let store = HuggingFaceTestSecrets(["huggingface": "manual-token"])
        let connection = huggingFaceTestConnection(store, HuggingFaceAuthFixture())
        let config = try connection.storedTokenConfiguration()
        #expect(config.manualToken == "manual-token")
        #expect(config.oauthToken == nil)
        #expect(store.writes.isEmpty)
    }

    @Test func sharedRefreshRotatesAndPersistsBeforeBothCallersReturn() async throws {
        let store = try HuggingFaceTestSecrets([HuggingFaceSession.oauthAccount: huggingFaceSavedRecord(expired: true)])
        let fixture = HuggingFaceAuthFixture()
        await fixture.configure(holdToken: true)
        let session = huggingFaceTestSession(store, fixture)
        let first = Task { try await session.optionalAccessToken() }
        let second = Task { try await session.optionalAccessToken() }
        await fixture.waitForTokenRequest()
        await fixture.releaseToken()
        #expect(try await first.value == "fresh-access")
        #expect(try await second.value == "fresh-access")
        #expect(await fixture.requests.count == 1)
        let record = try Self.record(store)
        #expect(record.tokens?.refreshToken == "fresh-refresh")
        #expect(record.tokens?.expiresAt == huggingFaceTestNow.addingTimeInterval(3600))
        let fields = try Self.fields(#require(await fixture.requests.first))
        #expect(fields == [
            "grant_type": "refresh_token",
            "client_id": "fixture-public-client",
            "refresh_token": "old-refresh",
        ])
    }

    @Test func cancellingOneConsumerDoesNotCancelSharedRotation() async throws {
        let store = try HuggingFaceTestSecrets([HuggingFaceSession.oauthAccount: huggingFaceSavedRecord(expired: true)])
        let fixture = HuggingFaceAuthFixture(); await fixture.configure(holdToken: true)
        let session = huggingFaceTestSession(store, fixture)
        let cancelled = Task { try await session.optionalAccessToken() }
        let retained = Task { try await session.optionalAccessToken() }
        await fixture.waitForTokenRequest()
        cancelled.cancel()
        await fixture.releaseToken()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await retained.value == "fresh-access")
        #expect(await fixture.cancelledRequests == 0)
        #expect(await fixture.requests.count == 1)
    }

    @Test(arguments: [400, 503])
    func refreshFailureNeverFallsBackToManual(status: Int) async throws {
        let store = try HuggingFaceTestSecrets([
            HuggingFaceSession.oauthAccount: huggingFaceSavedRecord(expired: true), "huggingface": "stale-manual",
        ])
        let fixture = HuggingFaceAuthFixture()
        await fixture.configure(
            tokenStatus: status,
            tokenError: status == 400 ? "invalid_grant" : "temporarily_unavailable"
        )
        let connection = huggingFaceTestConnection(store, fixture)
        await #expect(throws: HuggingFaceAuthError.self) { try await connection.optionalAccessToken() }
        #expect(connection.usesOAuth)
        #expect(connection.status.needsSignIn == (status == 400))
        #expect(try (Self.record(store).tokens == nil) == (status == 400))
        #expect(store.values["huggingface"] == "stale-manual")
        #expect(!store.reads.contains("huggingface"))
    }

    @Test func refreshRetainsOmittedRefreshTokenAndDoesNotInventExpiry() async throws {
        let store = try HuggingFaceTestSecrets([HuggingFaceSession.oauthAccount: huggingFaceSavedRecord(expired: true)])
        let fixture = HuggingFaceAuthFixture(); await fixture.configure(rotateRefresh: false, expiresIn: nil)
        let connection = huggingFaceTestConnection(store, fixture)
        #expect(try await connection.accessToken() == "fresh-access")
        let record = try Self.record(store)
        #expect(record.tokens?.refreshToken == "old-refresh")
        #expect(record.tokens?.expiresAt == nil)
    }

    @Test func failedRotationPersistenceDoesNotReleaseNewToken() async throws {
        let store = try HuggingFaceTestSecrets([HuggingFaceSession.oauthAccount: huggingFaceSavedRecord(expired: true)])
        store.rejectWrites(to: HuggingFaceSession.oauthAccount)
        let connection = huggingFaceTestConnection(store, HuggingFaceAuthFixture())
        await #expect(throws: StudioError.self) { try await connection.accessToken() }
        #expect(connection.status.needsSignIn)
        await #expect(throws: HuggingFaceAuthError.self) { try await connection.accessToken() }
        #expect(try Self.record(store).tokens?.accessToken == "old-access")
    }

    @Test func signOutDrainsLateRefreshAndRemovesManualFirst() async throws {
        let store = try HuggingFaceTestSecrets([
            HuggingFaceSession.oauthAccount: huggingFaceSavedRecord(expired: true), "huggingface": "stale-manual",
        ])
        let fixture = HuggingFaceAuthFixture(); await fixture.configure(holdToken: true)
        let session = huggingFaceTestSession(store, fixture)
        let refreshing = Task { try await session.optionalAccessToken() }
        await fixture.waitForTokenRequest()
        let signingOut = Task { try await session.signOut() }
        await fixture.waitForRequestCancellation()
        await fixture.releaseToken()
        try await signingOut.value
        await #expect(throws: CancellationError.self) { try await refreshing.value }
        #expect(store.values.isEmpty)
        #expect(store.writes == ["huggingface", HuggingFaceSession.oauthAccount])
        #expect(try await session.optionalAccessToken() == nil)
    }

    @Test(arguments: ["signout", "manual"])
    func lateSignInCannotRestoreCredentialsAfterExplicitChange(change: String) async throws {
        let store = HuggingFaceTestSecrets(["huggingface": "old-manual"]), fixture = HuggingFaceAuthFixture()
        await fixture.configure(holdToken: true)
        let session = huggingFaceTestSession(store, fixture)
        let signingIn = Task { try await session.signIn() }
        await fixture.waitForTokenRequest()
        if change == "signout" { try await session.signOut() } else { try await session.saveManualToken("replacement") }
        await fixture.releaseToken()
        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(store.values[HuggingFaceSession.oauthAccount] == nil)
        #expect(store.values["huggingface"] == (change == "manual" ? "replacement" : nil))
    }

    @Test(arguments: ["huggingface", "huggingface.oauth"])
    func failedSignOutDoesNotExposeOldManualCredential(failedAccount: String) async throws {
        let store = try HuggingFaceTestSecrets([
            HuggingFaceSession.oauthAccount: huggingFaceSavedRecord(), "huggingface": "stale-manual",
        ])
        store.rejectWrites(to: failedAccount)
        let connection = huggingFaceTestConnection(store, HuggingFaceAuthFixture())
        await connection.load()
        #expect(await !connection.signOut())
        #expect(connection.usesOAuth)
        await #expect(throws: HuggingFaceAuthError.self) { try await connection.accessToken() }
        #expect(store.values[HuggingFaceSession.oauthAccount] != nil)
        #expect((store.values["huggingface"] != nil) == (failedAccount == "huggingface"))
    }

    @Test func failedOAuthRemovalDuringManualSwitchKeepsOAuthSelected() async throws {
        let store = try HuggingFaceTestSecrets([HuggingFaceSession.oauthAccount: huggingFaceSavedRecord()])
        store.rejectWrites(to: HuggingFaceSession.oauthAccount)
        let connection = huggingFaceTestConnection(store, HuggingFaceAuthFixture())
        #expect(await !connection.saveManualToken("replacement"))
        #expect(connection.usesOAuth)
        #expect(try await connection.accessToken() == "old-access")
        #expect(store.values["huggingface"] == "replacement")
    }

    @Test func cancellationClosesPendingBrowserCallbackWithoutChangingAccount() async {
        let store = HuggingFaceTestSecrets(["huggingface": "existing"]), fixture = HuggingFaceAuthFixture()
        await fixture.configure(holdCallback: true)
        let connection = huggingFaceTestConnection(store, fixture)
        let signingIn = Task { await connection.signIn() }
        await fixture.waitForBrowser()
        await connection.cancelAndWait()
        #expect(await !signingIn.value)
        #expect(await fixture.callbackCancelled)
        #expect(await fixture.requests.isEmpty)
        #expect(store.values == ["huggingface": "existing"])
        #expect(connection.errorMessage == nil)
    }

    @Test(arguments: ["origin", "port", "path", "state", "duplicate", "empty", "fragment"])
    func callbackRefusesMismatchedOrAmbiguousInput(problem: String) throws {
        let attempt =
            try HuggingFaceAuthorization(redirectURI: #require(URL(string: "http://127.0.0.1:14555/auth/callback")))
        var parts = try #require(URLComponents(string: "http://127.0.0.1:14555/auth/callback"))
        parts.queryItems = [
            URLQueryItem(name: "state", value: attempt.state),
            URLQueryItem(name: "code", value: "code"),
        ]
        switch problem {
        case "origin": parts.host = "example.invalid"
        case "port": parts.port = 9999
        case "path": parts.path = "/wrong"
        case "state": parts.queryItems?[0].value = "wrong"
        case "duplicate": parts.queryItems?.append(URLQueryItem(name: "state", value: attempt.state))
        case "empty": parts.queryItems?[1].value = ""
        case "fragment": parts.fragment = "unexpected"
        default: break
        }
        #expect(throws: HuggingFaceAuthError.self) { try attempt.exchangeRequest(callback: #require(parts.url)) }
    }

    private static func fields(_ request: URLRequest) -> [String: String] {
        let encoded = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        return Dictionary(uniqueKeysWithValues: URLComponents(string: "https://fixture.invalid/?" + encoded)!
            .queryItems!.map { ($0.name, $0.value!) })
    }

    private static func record(_ store: HuggingFaceTestSecrets) throws -> HuggingFaceOAuthRecord {
        let text = try #require(store.values[HuggingFaceSession.oauthAccount])
        return try JSONDecoder().decode(HuggingFaceOAuthRecord.self, from: Data(text.utf8))
    }
}
