import Foundation

/// The available translation backends.
enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case googleFree = "GoogleFree"
    case openAI = "OpenAI"
    case chatGPT = "ChatGPT"
    case local = "Local"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .googleFree: return "Google (free endpoint)"
        case .openAI: return "OpenAI"
        case .chatGPT: return "ChatGPT subscription"
        case .local: return "Local model"
        }
    }

    var blurb: String {
        switch self {
        case .googleFree:
            return "No setup, no key. Uses the public translate endpoint — fast, but your text leaves the machine."
        case .openAI:
            return "Chat completions against api.openai.com. Needs an API key."
        case .chatGPT:
            return "Sign in with ChatGPT. Uses Codex subscription access; this endpoint may change."
        case .local:
            return "Any OpenAI-compatible server on your machine — llama.cpp, LM Studio, Ollama, Jan. Nothing leaves the machine."
        }
    }

    var requiresAPIKey: Bool { self == .openAI }

    /// Prompt-driven backends are the ones worth exposing prompt editing for.
    var usesPrompts: Bool { self != .googleFree }

    /// Only the local backend lets you point at an arbitrary host; the others
    /// each have exactly one address.
    var hasEditableEndpoint: Bool { self == .local }
}

/// An immutable snapshot of everything a provider needs to run one request.
///
/// Settings are read once, here, rather than by the provider mid-flight. The
/// snapshot *is* the provider's storage, so a provider is `Sendable` by
/// construction and a request already in the air can't be changed out from under
/// itself when you edit a field.
struct ProviderConfig: Sendable, Equatable {
    var kind: ProviderKind = .googleFree
    var endpoint: String = ""
    var model: String = ""
    var apiKey: String = ""
    var systemPrompt: String = PromptTemplate.defaultSystem
    var userPrompt: String = PromptTemplate.defaultUser
    var temperature: Double = 0
    var timeout: TimeInterval = 180
    var stream: Bool = true
}

/// UserDefaults-backed settings. The API key is the one exception — it lives in
/// the keychain.
@MainActor
final class ProviderSettings: ObservableObject {
    static let shared = ProviderSettings()

    nonisolated static let defaultLocalEndpoint = "http://127.0.0.1:8080/v1"
    nonisolated static let chatGPTModel = "gpt-5.5"

    private enum Key {
        static let kind = "provider.kind"
        static let localEndpoint = "provider.local.endpoint"
        static let model = "provider.model"
        static let systemPrompt = "provider.systemPrompt"
        static let userPrompt = "provider.userPrompt"
        static let temperature = "provider.temperature"
        static let timeout = "provider.timeout"
        static let stream = "provider.stream"
        static let autoTranslate = "ui.autoTranslate"
        static let sourceLanguage = "ui.sourceLanguage"
        static let targetLanguage = "ui.targetLanguage"
        static let didCompleteSetup = "ui.didCompleteSetup"
    }

    private let defaults = UserDefaults.standard

    @Published var kind: ProviderKind { didSet { defaults.set(kind.rawValue, forKey: Key.kind) } }
    @Published var localEndpoint: String { didSet { defaults.set(localEndpoint, forKey: Key.localEndpoint) } }
    @Published var model: String { didSet { defaults.set(model, forKey: Key.model) } }
    @Published var systemPrompt: String { didSet { defaults.set(systemPrompt, forKey: Key.systemPrompt) } }
    @Published var userPrompt: String { didSet { defaults.set(userPrompt, forKey: Key.userPrompt) } }
    @Published var temperature: Double { didSet { defaults.set(temperature, forKey: Key.temperature) } }
    @Published var timeout: TimeInterval { didSet { defaults.set(timeout, forKey: Key.timeout) } }
    @Published var stream: Bool { didSet { defaults.set(stream, forKey: Key.stream) } }
    @Published var autoTranslate: Bool { didSet { defaults.set(autoTranslate, forKey: Key.autoTranslate) } }
    @Published var sourceLanguage: String { didSet { defaults.set(sourceLanguage, forKey: Key.sourceLanguage) } }
    @Published var targetLanguage: String { didSet { defaults.set(targetLanguage, forKey: Key.targetLanguage) } }
    @Published var didCompleteSetup: Bool { didSet { defaults.set(didCompleteSetup, forKey: Key.didCompleteSetup) } }
    @Published var chatGPTConnected: Bool

    /// Written through to the keychain so a key never lands in a plist that
    /// backups and screen-sharing sessions can read.
    @Published var apiKey: String {
        didSet {
            guard apiKey != oldValue else { return }
            Keychain.setAPIKey(apiKey)
        }
    }

    init() {
        kind = ProviderKind(rawValue: defaults.string(forKey: Key.kind) ?? "") ?? .googleFree
        localEndpoint = defaults.string(forKey: Key.localEndpoint) ?? Self.defaultLocalEndpoint
        model = defaults.string(forKey: Key.model) ?? ""
        systemPrompt = defaults.string(forKey: Key.systemPrompt) ?? PromptTemplate.defaultSystem
        userPrompt = defaults.string(forKey: Key.userPrompt) ?? PromptTemplate.defaultUser
        temperature = defaults.object(forKey: Key.temperature) as? Double ?? 0
        timeout = defaults.object(forKey: Key.timeout) as? TimeInterval ?? 180
        stream = defaults.object(forKey: Key.stream) as? Bool ?? true
        autoTranslate = defaults.object(forKey: Key.autoTranslate) as? Bool ?? true
        sourceLanguage = defaults.string(forKey: Key.sourceLanguage) ?? Language.auto.code
        targetLanguage = defaults.string(forKey: Key.targetLanguage) ?? "es"
        didCompleteSetup = defaults.bool(forKey: Key.didCompleteSetup)
        apiKey = Keychain.apiKey() ?? ""
        chatGPTConnected = ChatGPTAuth.isSignedIn
    }

    /// Take the snapshot a provider will run against.
    func snapshot() -> ProviderConfig {
        ProviderConfig(
            kind: kind,
            endpoint: kind.hasEditableEndpoint ? localEndpoint : "",
            model: kind == .chatGPT ? Self.chatGPTModel : model,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: temperature,
            timeout: timeout,
            stream: stream
        )
    }

    /// What still needs filling in before a translation can run.
    var configurationProblem: String? {
        switch kind {
        case .googleFree:
            return nil
        case .openAI:
            if apiKey.trimmed.isEmpty { return "Add an OpenAI API key in Settings." }
            if model.trimmed.isEmpty { return "Pick a model in Settings." }
            return nil
        case .chatGPT:
            return chatGPTConnected ? nil : "Sign in with ChatGPT in provider settings."
        case .local:
            if localEndpoint.trimmed.isEmpty { return "Set the local server endpoint in Settings." }
            if model.trimmed.isEmpty { return "Pick a model in Settings." }
            return nil
        }
    }

    func resetPrompts() {
        systemPrompt = PromptTemplate.defaultSystem
        userPrompt = PromptTemplate.defaultUser
    }

    var promptsAreDefault: Bool {
        systemPrompt == PromptTemplate.defaultSystem && userPrompt == PromptTemplate.defaultUser
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
