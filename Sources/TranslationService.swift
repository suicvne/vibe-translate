import Foundation

/// Routing layer: picks a backend for the current configuration and hands back a
/// ready provider.
///
/// A provider is a value-like wrapper around an immutable snapshot, so building
/// one per request is cheaper than caching one and tracking whether it is still
/// current.
enum TranslationService {
    static func provider(for config: ProviderConfig) -> TranslationProvider {
        switch config.kind {
        case .openAI: return OpenAIProvider(config: config)
        case .chatGPT: return ChatGPTProvider(config: config)
        case .local: return LocalOpenAIProvider(config: config)
        case .googleFree: return GoogleFreeProvider(config: config)
        }
    }

    /// Providers that can enumerate models — Google's endpoint cannot.
    static func modelLister(for config: ProviderConfig) -> ModelListingProvider? {
        provider(for: config) as? ModelListingProvider
    }

    static func translate(_ text: String, from source: String, to target: String,
                          config: ProviderConfig) async throws -> String {
        try await provider(for: config).translate(text, from: source, to: target)
    }
}
