import ConceptCore
import CryptoKit
import Foundation

struct HuggingFaceAuthError: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

struct HuggingFaceAuthorization {
    static let clientID = "b2555a1a-fdaf-46dd-a4e3-7863407fb2f8"
    static let scopes = ["openid", "profile", "contribute-repos", "write-repos", "gated-repos"]
    static let tokenURL = URL(string: "https://huggingface.co/oauth/token")!
    static let userInfoURL = URL(string: "https://huggingface.co/oauth/userinfo")!
    static let applicationsURL = URL(string: "https://huggingface.co/settings/connected-applications")!

    let clientID: String
    let redirectURI: URL
    let verifier: String
    let state: String

    init(redirectURI: URL, clientID: String = Self.clientID) throws {
        guard !clientID.isEmpty else { throw HuggingFaceAuthError("Hugging Face sign-in is not configured.") }
        self.clientID = clientID
        self.redirectURI = redirectURI
        verifier = try ChatGPTAuth.randomValue(bytes: 64)
        state = try ChatGPTAuth.randomValue()
    }

    var browserURL: URL {
        var parts = URLComponents(string: "https://huggingface.co/oauth/authorize")!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(
                name: "code_challenge",
                value: ChatGPTAuth.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
            ),
        ]
        return parts.url!
    }

    func exchangeRequest(callback: URL) throws -> URLRequest {
        guard callback.scheme == redirectURI.scheme, callback.host() == redirectURI.host(),
              callback.port == redirectURI.port, callback.path() == redirectURI.path(),
              callback.user == nil, callback.password == nil, callback.fragment == nil,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw HuggingFaceAuthError("Hugging Face's callback did not match this sign-in. Try again.")
        }
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil, let value = item.value else {
                throw HuggingFaceAuthError("Hugging Face returned an ambiguous sign-in response. Try again.")
            }
            values[item.name] = value
        }
        guard values["state"] == state else {
            throw HuggingFaceAuthError("Hugging Face's sign-in state did not match. Try again.")
        }
        if let error = values["error"] {
            throw HuggingFaceAuthError(error == "access_denied"
                ? "Hugging Face sign-in was declined. Your saved account was not changed."
                : "Hugging Face could not finish sign-in. Try again.")
        }
        guard let code = values["code"], !code.isEmpty else {
            throw HuggingFaceAuthError("Hugging Face did not return a sign-in code. Try again.")
        }
        return Self.tokenRequest([
            "grant_type": "authorization_code", "client_id": clientID,
            "code": code, "code_verifier": verifier, "redirect_uri": redirectURI.absoluteString,
        ])
    }

    static func tokenRequest(_ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTAuth.form(fields)
        return request
    }
}

struct HuggingFaceProfile: Codable, Equatable, Sendable {
    let subject: String
    let username: String
    let displayName: String?

    init(data: Data, oauth: Bool) throws {
        let body = try JSONValue(parsing: data).objectValue
        guard let username = body?[oauth ? "preferred_username" : "name"]?.stringValue,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let subject = body?[oauth ? "sub" : "id"]?.stringValue, !subject.isEmpty else {
            throw HuggingFaceAuthError("Hugging Face did not return an account identity. Connect again.")
        }
        self.subject = subject
        self.username = username
        displayName = body?[oauth ? "name" : "fullname"]?.stringValue
    }
}

struct HuggingFaceTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let scopes: Set<String>
}

struct HuggingFaceOAuthRecord: Codable, Sendable {
    let clientID: String
    let profile: HuggingFaceProfile
    var tokens: HuggingFaceTokens?
}

struct HuggingFaceTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let expiresIn: Double?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", tokenType = "token_type"
        case expiresIn = "expires_in", scope
    }

    func tokens(previous: HuggingFaceTokens? = nil, now: Date) throws -> HuggingFaceTokens {
        guard tokenType.lowercased() == "bearer", !accessToken.isEmpty,
              refreshToken == nil || refreshToken?.isEmpty == false,
              expiresIn == nil || (expiresIn!.isFinite && expiresIn! > 0) else {
            throw HuggingFaceAuthError("Hugging Face returned incomplete credentials. Sign in again.")
        }
        // OAuth omits scope when it is unchanged. Never invent an expiry or a refresh grant.
        let scopes = scope.map { Set($0.split(whereSeparator: \.isWhitespace).map(String.init)) }
            ?? previous?.scopes ?? Set(HuggingFaceAuthorization.scopes)
        guard Set(HuggingFaceAuthorization.scopes).isSubset(of: scopes) else {
            throw HuggingFaceAuthError(
                "Allow repository publishing and gated-model access when signing in with Hugging Face."
            )
        }
        return HuggingFaceTokens(
            accessToken: accessToken, refreshToken: refreshToken ?? previous?.refreshToken,
            expiresAt: expiresIn.map { now.addingTimeInterval($0) }, scopes: scopes
        )
    }
}
