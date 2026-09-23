import Foundation

/// ChatGPT's Codex OAuth flow. This is separate from OpenAI Platform API keys.
enum ChatGPTAuth {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!
    private static let userCodeURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
    private static let deviceTokenURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let redirectURI = "https://auth.openai.com/deviceauth/callback"

    struct Credentials: Codable, Sendable {
        let accessToken: String
        let refreshToken: String
        let accountID: String
        let expiresAt: Date
    }

    struct DeviceCode: Sendable {
        let id: String
        let code: String
        let interval: TimeInterval
    }

    static var isSignedIn: Bool { Keychain.chatGPTCredentials() != nil }

    static func signOut() { Keychain.setChatGPTCredentials(nil) }

    static func startDeviceLogin(session: URLSession = .shared) async throws -> DeviceCode {
        let request = jsonRequest(userCodeURL, body: ["client_id": clientID])
        let data = try await send(request, session: session)
        let body = try object(data)
        guard let id = body["device_auth_id"] as? String,
              let code = body["user_code"] as? String,
              !id.isEmpty, !code.isEmpty else {
            throw TranslationError.malformedResponse("ChatGPT sign-in")
        }
        let interval = (body["interval"] as? NSNumber)?.doubleValue
            ?? (body["interval"] as? String).flatMap(Double.init) ?? 5
        return DeviceCode(id: id, code: code, interval: min(30, max(1, interval)))
    }

    static func finishDeviceLogin(_ device: DeviceCode, session: URLSession = .shared) async throws {
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: UInt64(device.interval * 1_000_000_000))
            try Task.checkCancellation()
            let request = jsonRequest(deviceTokenURL, body: [
                "device_auth_id": device.id, "user_code": device.code,
            ])
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TranslationError.transport("ChatGPT sign-in returned no HTTP response.")
            }
            if http.statusCode == 403 || http.statusCode == 404 { continue }
            guard (200...299).contains(http.statusCode) else {
                throw TranslationError.http(status: http.statusCode, body: "ChatGPT device sign-in failed.")
            }
            let body = try object(data)
            guard let code = body["authorization_code"] as? String,
                  let verifier = body["code_verifier"] as? String else {
                throw TranslationError.malformedResponse("ChatGPT sign-in")
            }
            let form = [
                "grant_type": "authorization_code", "client_id": clientID,
                "code": code, "code_verifier": verifier, "redirect_uri": redirectURI,
            ]
            let credentials = try await exchange(form, session: session)
            guard Keychain.setChatGPTCredentials(try JSONEncoder().encode(credentials)) else {
                throw TranslationError.transport("Could not save ChatGPT sign-in to the login keychain.")
            }
            return
        }
        throw TranslationError.transport("ChatGPT sign-in timed out. Try again.")
    }

    static func validCredentials(session: URLSession = .shared, forceRefresh: Bool = false) async throws -> Credentials {
        guard let data = Keychain.chatGPTCredentials(),
              let stored = try? JSONDecoder().decode(Credentials.self, from: data) else {
            throw TranslationError.transport("Sign in with ChatGPT in provider settings.")
        }
        if !forceRefresh && stored.expiresAt.timeIntervalSinceNow > 60 { return stored }
        let refreshed = try await exchange([
            "grant_type": "refresh_token", "client_id": clientID,
            "refresh_token": stored.refreshToken,
        ], previous: stored, session: session)
        guard Keychain.setChatGPTCredentials(try JSONEncoder().encode(refreshed)) else {
            throw TranslationError.transport("Could not save refreshed ChatGPT sign-in.")
        }
        return refreshed
    }

    private static func exchange(_ form: [String: String], previous: Credentials? = nil,
                                 session: URLSession) async throws -> Credentials {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.sorted { $0.key < $1.key }.map {
            "\($0.key.urlFormEncoded)=\($0.value.urlFormEncoded)"
        }.joined(separator: "&").data(using: .utf8)
        let data = try await send(request, session: session)
        let body = try object(data)
        guard let access = body["access_token"] as? String,
              let refresh = body["refresh_token"] as? String ?? previous?.refreshToken,
              let expires = body["expires_in"] as? NSNumber else {
            throw TranslationError.malformedResponse("ChatGPT sign-in")
        }
        let accountID = Self.accountID(in: access)
            ?? (body["id_token"] as? String).flatMap { Self.accountID(in: $0) }
            ?? previous?.accountID
        guard let accountID, !accountID.isEmpty else {
            throw TranslationError.malformedResponse("ChatGPT account identity")
        }
        return Credentials(accessToken: access, refreshToken: refresh, accountID: accountID,
                           expiresAt: Date().addingTimeInterval(expires.doubleValue))
    }

    static func accountID(in token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = body["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String
    }

    private static func jsonRequest(_ url: URL, body: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try OpenAICompatibleProvider.checkStatus(response, body: data)
        return data
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.malformedResponse("ChatGPT sign-in")
        }
        return body
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
    }
}
