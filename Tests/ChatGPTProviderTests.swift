import Foundation

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.requestHandler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@main
struct ChatGPTProviderTests {
    static func main() async throws {
        try await deviceLoginRequest()
        try codexRequest()
        responseEvents()
        accountClaim()
        existingProvidersStillRoute()
        print("ChatGPT provider tests passed")
    }

    private static func deviceLoginRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.requestHandler = { request in
            precondition(request.url?.absoluteString == "https://auth.openai.com/api/accounts/deviceauth/usercode")
            precondition(request.httpMethod == "POST")
            let bodyData: Data
            if let body = request.httpBody {
                bodyData = body
            } else {
                let stream = request.httpBodyStream!
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 1024)
                let count = stream.read(&bytes, maxLength: bytes.count)
                precondition(count > 0)
                bodyData = Data(bytes.prefix(count))
            }
            let body = try JSONSerialization.jsonObject(with: bodyData) as! [String: String]
            precondition(body["client_id"] == ChatGPTAuth.clientID)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"device_auth_id":"device","user_code":"ABCD-EFGH","interval":"7"}"#.utf8))
        }
        let code = try await ChatGPTAuth.startDeviceLogin(session: session)
        precondition(code.id == "device" && code.code == "ABCD-EFGH" && code.interval == 7)
        session.invalidateAndCancel()
        MockURLProtocol.requestHandler = nil
    }

    private static func codexRequest() throws {
        let credentials = ChatGPTAuth.Credentials(accessToken: "test-access", refreshToken: "test-refresh",
                                                   accountID: "test-account", expiresAt: .distantFuture)
        let request = try ChatGPTProvider.request(model: "gpt-5.5", system: "Translate to Spanish.",
                                                  user: "Hello", credentials: credentials, timeout: 30)
        precondition(request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access")
        precondition(request.value(forHTTPHeaderField: "chatgpt-account-id") == "test-account")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(body["model"] as? String == "gpt-5.5")
        precondition(body["instructions"] as? String == "Translate to Spanish.")
        precondition(body["stream"] as? Bool == true && body["store"] as? Bool == false)
        precondition(body["temperature"] == nil && body["messages"] == nil && body["max_tokens"] == nil)
        let input = body["input"] as! [[String: Any]]
        let content = input[0]["content"] as! [[String: String]]
        precondition(input[0]["role"] as? String == "user" && content[0]["text"] == "Hello")
    }

    private static func responseEvents() {
        precondition(ChatGPTProvider.delta(from: #"data: {"type":"response.output_text.delta","delta":"Hola"}"#) == "Hola")
        precondition(ChatGPTProvider.delta(from: "data: [DONE]") == nil)
        precondition(ChatGPTProvider.failure(from: #"data: {"type":"response.failed","response":{"error":{"message":"denied"}}}"#) == "denied")
    }

    private static func accountClaim() {
        let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"account-123"}}"#.utf8)
        let token = "header.\(payload.base64EncodedString()).signature"
        precondition(ChatGPTAuth.accountID(in: token) == "account-123")
        precondition(ChatGPTAuth.accountID(in: "invalid") == nil)
    }

    private static func existingProvidersStillRoute() {
        precondition(TranslationService.provider(for: ProviderConfig(kind: .openAI)) is OpenAIProvider)
        precondition(TranslationService.provider(for: ProviderConfig(kind: .local)) is LocalOpenAIProvider)
        precondition(TranslationService.provider(for: ProviderConfig(kind: .chatGPT)) is ChatGPTProvider)
    }
}
