import AppKit
import SwiftUI

/// Asks the chosen backend what models it has, so the model menu reflects what
/// the server will actually accept.
@MainActor
final class ModelCatalog: ObservableObject {
    @Published private(set) var models: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var failed = false

    private var job: Task<Void, Never>?

    func load(_ config: ProviderConfig) {
        guard let lister = TranslationService.modelLister(for: config) else {
            models = []
            message = "This backend has no model list."
            failed = false
            return
        }

        job?.cancel()
        isLoading = true
        message = nil
        failed = false

        job = Task {
            do {
                let found = try await lister.availableModels()
                if Task.isCancelled { return }
                models = found
                failed = false
                message = "Connected — \(found.count) model\(found.count == 1 ? "" : "s") available."
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                models = []
                failed = true
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isLoading = false
        }
    }

    func reset() {
        job?.cancel()
        models = []
        message = nil
        failed = false
        isLoading = false
    }
}

/// The backend picker and its per-backend fields. Shared by the first-run sheet
/// and the Settings window so both stay in step.
struct ProviderConfigForm: View {
    @EnvironmentObject private var settings: ProviderSettings
    @ObservedObject var catalog: ModelCatalog
    @State private var deviceCode: String?
    @State private var signInMessage: String?
    @State private var loginTask: Task<Void, Never>?

    /// Local servers people actually run, so nobody has to remember port numbers.
    private static let presets: [(name: String, url: String)] = [
        ("llama.cpp", "http://127.0.0.1:8080/v1"),
        ("LM Studio", "http://127.0.0.1:1234/v1"),
        ("Ollama", "http://127.0.0.1:11434/v1"),
        ("Jan", "http://127.0.0.1:1337/v1"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            backendPicker

            switch settings.kind {
            case .googleFree:
                Text(ProviderKind.googleFree.blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .openAI:
                apiKeyField
                modelField
            case .chatGPT:
                chatGPTField
            case .local:
                endpointField
                modelField
            }

            if let message = catalog.message {
                Label(message, systemImage: catalog.failed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(catalog.failed ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: settings.kind) { _ in catalog.reset() }
        .onDisappear { loginTask?.cancel() }
    }

    // MARK: - Fields

    private var backendPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Backend", selection: $settings.kind) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if settings.kind != .googleFree {
                Text(settings.kind.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API key").font(.callout).foregroundStyle(.secondary)
            HStack {
                SecureField("sk-…", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
                fetchButton
            }
            Text("Stored in your login keychain, not in preferences.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var chatGPTField: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settings.chatGPTConnected {
                Label("Signed in with ChatGPT", systemImage: "checkmark.circle")
                Button("Sign out") {
                    ChatGPTAuth.signOut()
                    settings.chatGPTConnected = false
                    deviceCode = nil
                }
            } else {
                Button(loginTask == nil ? "Sign in with ChatGPT" : "Waiting for sign-in…") {
                    loginTask = Task { await signIn() }
                }
                .disabled(loginTask != nil)
                if let deviceCode {
                    HStack {
                        Text("Enter code \(deviceCode) at the page opened in your browser.")
                            .textSelection(.enabled)
                        Button("Copy code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(deviceCode, forType: .string)
                        }
                    }
                }
            }
            if let signInMessage {
                Text(signInMessage).font(.caption).foregroundStyle(.secondary)
            }
            Text("Uses the Codex subscription endpoint. Its protocol is not a public OpenAI API and may change.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    @MainActor
    private func signIn() async {
        defer { loginTask = nil }
        do {
            signInMessage = nil
            let device = try await ChatGPTAuth.startDeviceLogin()
            deviceCode = device.code
            NSWorkspace.shared.open(ChatGPTAuth.verificationURL)
            try await ChatGPTAuth.finishDeviceLogin(device)
            settings.chatGPTConnected = true
            deviceCode = nil
            signInMessage = "Connected."
        } catch is CancellationError {
            deviceCode = nil
        } catch {
            signInMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var endpointField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Endpoint").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Menu("Presets") {
                    ForEach(Self.presets, id: \.url) { preset in
                        Button("\(preset.name) — \(preset.url)") {
                            settings.localEndpoint = preset.url
                            catalog.reset()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 90)
            }
            HStack {
                TextField(ProviderSettings.defaultLocalEndpoint, text: $settings.localEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { catalog.load(settings.snapshot()) }
                fetchButton
            }
        }
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("model name", text: $settings.model)
                    .textFieldStyle(.roundedBorder)

                Menu("") {
                    if catalog.models.isEmpty {
                        Text("No models loaded")
                    }
                    ForEach(catalog.models, id: \.self) { name in
                        Button(name) { settings.model = name }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 16)
                .disabled(catalog.models.isEmpty)
                .help("Choose from the models the server reported")
            }
        }
    }

    private var fetchButton: some View {
        Button {
            catalog.load(settings.snapshot())
        } label: {
            if catalog.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 40)
            } else {
                Text("Connect")
            }
        }
        .disabled(catalog.isLoading)
    }
}
