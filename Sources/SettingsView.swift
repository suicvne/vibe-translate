import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: ProviderSettings

    var body: some View {
        TabView {
            BackendSettings()
                .tabItem { Label("Backend", systemImage: "server.rack") }
            PromptSettings()
                .tabItem { Label("Prompts", systemImage: "text.quote") }
            BehaviourSettings()
                .tabItem { Label("Behaviour", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 540, height: 430)
    }
}

private struct BackendSettings: View {
    @EnvironmentObject private var settings: ProviderSettings
    @StateObject private var catalog = ModelCatalog()

    var body: some View {
        VStack(alignment: .leading) {
            ProviderConfigForm(catalog: catalog)
                .environmentObject(settings)
            Spacer()
        }
        .padding(20)
    }
}

/// Requirement six, and the reason this app is more than a search box: the
/// instructions a local model receives are editable, because a 7B model that
/// rambles usually needs a firmer prompt rather than a different app.
private struct PromptSettings: View {
    @EnvironmentObject private var settings: ProviderSettings
    @State private var showPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !settings.kind.usesPrompts {
                Label("The Google endpoint takes no prompt — these apply to OpenAI, ChatGPT, and local models.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("System prompt").font(.callout).foregroundStyle(.secondary)
            promptEditor(text: $settings.systemPrompt, minHeight: 130)

            Text("User message").font(.callout).foregroundStyle(.secondary)
            promptEditor(text: $settings.userPrompt, minHeight: 52)

            Text("Placeholders: " + PromptTemplate.placeholders.joined(separator: "  "))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)

            if showPreview {
                ScrollView {
                    Text(preview)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 90)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Toggle("Show filled preview", isOn: $showPreview)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Restore Defaults", action: settings.resetPrompts)
                    .disabled(settings.promptsAreDefault)
            }
        }
        .padding(20)
    }

    private func promptEditor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: minHeight)
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    /// Exactly what the model will be sent for the languages currently selected.
    private var preview: String {
        let source = settings.sourceLanguage
        let target = settings.targetLanguage
        let system = PromptTemplate.fill(settings.systemPrompt, text: nil, from: source, to: target)
        let user = PromptTemplate.fill(settings.userPrompt, text: "Hello, world.",
                                       from: source, to: target)
        return "system:\n\(system)\n\nuser:\n\(user)"
    }
}

private struct BehaviourSettings: View {
    @EnvironmentObject private var settings: ProviderSettings

    var body: some View {
        Form {
            Section {
                Toggle("Translate as I type", isOn: $settings.autoTranslate)
                Text("Off means translations only run on ⌘↩ or the Translate button.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section {
                Toggle("Stream the response", isOn: $settings.stream)
                    .disabled(!settings.kind.usesPrompts)
                Text("Shows a local model's output as it is generated. Turn off if your server rejects streaming requests.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section {
                HStack {
                    Slider(value: $settings.temperature, in: 0...1, step: 0.05) {
                        Text("Temperature")
                    }
                    Text(String(format: "%.2f", settings.temperature))
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                .disabled(settings.kind == .googleFree || settings.kind == .chatGPT)
                Text("Zero keeps translations repeatable. Higher values invent more.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section {
                HStack {
                    Text("Request timeout")
                    Spacer()
                    Stepper(value: $settings.timeout, in: 10...600, step: 10) {
                        Text("\(Int(settings.timeout))s").monospacedDigit()
                    }
                }
                Text("A large model on a cold start can take minutes for the first token.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}
