import Foundation

/// Owns the in-flight request.
///
/// The view model is main-actor bound so published state is safe to read from
/// SwiftUI, but the provider call is a `nonisolated async` function: awaiting it
/// hands the work to the concurrency pool and frees the main thread until the
/// response lands. Typing never waits on the network, and every new keystroke
/// cancels the request the last one started.
@MainActor
final class TranslatorViewModel: ObservableObject {
    @Published var input = "" { didSet { inputChanged(from: oldValue) } }
    @Published private(set) var output = ""
    @Published private(set) var isTranslating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var status: String?

    private let settings: ProviderSettings
    private var job: Task<Void, Never>?

    init(settings: ProviderSettings) {
        self.settings = settings
    }

    /// Long enough that a local model is not asked to translate every keystroke,
    /// short enough that the free endpoint still feels live.
    private var debounce: Duration {
        settings.kind == .googleFree ? .milliseconds(500) : .milliseconds(1200)
    }

    var canTranslate: Bool {
        !input.trimmed.isEmpty && settings.configurationProblem == nil
    }

    // MARK: - Driving a translation

    private func inputChanged(from old: String) {
        guard input != old else { return }

        if input.trimmed.isEmpty {
            job?.cancel()
            job = nil
            output = ""
            errorMessage = nil
            status = nil
            isTranslating = false
            return
        }

        guard settings.autoTranslate else { return }
        start(after: debounce)
    }

    /// ⌘↩ and the Translate button: no waiting.
    func translateNow() {
        guard !input.trimmed.isEmpty else { return }
        start(after: .zero)
    }

    /// Re-run after a settings change, but only if there is something to re-run.
    func refreshIfNeeded() {
        guard settings.autoTranslate, !input.trimmed.isEmpty else { return }
        start(after: .milliseconds(150))
    }

    func cancel() {
        job?.cancel()
        job = nil
        isTranslating = false
        status = "Cancelled."
    }

    private func start(after delay: Duration) {
        job?.cancel()

        let text = input
        let source = settings.sourceLanguage
        let target = settings.targetLanguage
        let config = settings.snapshot()

        if let problem = settings.configurationProblem {
            errorMessage = problem
            return
        }

        job = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            await self?.run(text: text, source: source, target: target, config: config)
        }
    }

    private func run(text: String, source: String, target: String, config: ProviderConfig) async {
        isTranslating = true
        errorMessage = nil
        status = "Translating…"

        let started = ContinuousClock.now
        let provider = TranslationService.provider(for: config)

        do {
            if config.stream, let streaming = provider as? StreamingTranslationProvider {
                var raw = ""
                output = ""
                for try await piece in streaming.translateStream(text, from: source, to: target) {
                    try Task.checkCancellation()
                    raw += piece
                    // Show progress, but keep a model's reasoning block out of the box.
                    output = OpenAICompatibleProvider.stripReasoning(raw).trimmed
                }
                try Task.checkCancellation()
                output = OpenAICompatibleProvider.sanitize(raw)
            } else {
                let result = try await provider.translate(text, from: source, to: target)
                try Task.checkCancellation()
                output = result
            }

            let elapsed = started.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            status = String(format: "%@ · %.1fs", providerLabel(config), seconds)
        } catch is CancellationError {
            // Superseded by a newer keystroke; the newer run owns the UI now.
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = nil
        }

        isTranslating = false
    }

    private func providerLabel(_ config: ProviderConfig) -> String {
        guard (config.kind == .openAI || config.kind == .local), !config.model.trimmed.isEmpty else {
            return config.kind.displayName
        }
        return "\(config.kind.displayName) · \(config.model)"
    }

    // MARK: - Editing helpers

    /// There is nothing to swap into a "Detect language" slot, so the button
    /// that calls this is disabled in that state.
    var canSwapLanguages: Bool { settings.sourceLanguage != Language.auto.code }

    /// Swap the two sides, the way the web translator does: languages trade
    /// places and the translation becomes the new input.
    func swapLanguages() {
        guard canSwapLanguages else { return }

        let previousOutput = output
        let source = settings.sourceLanguage
        settings.sourceLanguage = settings.targetLanguage
        settings.targetLanguage = source

        if !previousOutput.isEmpty {
            input = previousOutput
        } else {
            refreshIfNeeded()
        }
    }

    func clear() {
        input = ""
    }
}
