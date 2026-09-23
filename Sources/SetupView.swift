import SwiftUI

/// Shown on first launch, and from File ▸ Set Up Provider… afterwards. The point
/// is that a local model can be selected and reached *before* anything is typed,
/// instead of discovering it is misconfigured through a failed translation.
struct SetupView: View {
    @EnvironmentObject private var settings: ProviderSettings
    @StateObject private var catalog = ModelCatalog()
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Translation backend")
                    .font(.title2.weight(.semibold))
                Text("Where your text gets translated. You can change this at any time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ProviderConfigForm(catalog: catalog)
                .environmentObject(settings)

            Spacer(minLength: 0)

            Text("Prompts, temperature and timeouts live in Settings (⌘,).")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack {
                if settings.kind != .googleFree {
                    Button("Use Google for now") {
                        settings.kind = .googleFree
                        finish()
                    }
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Start Translating", action: finish)
                    .keyboardShortcut(.defaultAction)
                    .disabled(settings.configurationProblem != nil)
            }
        }
        .padding(22)
        .frame(width: 520, height: 400)
        .onAppear {
            // A configured local server is worth probing right away — it tells
            // you it is reachable before you rely on it.
            if settings.kind == .openAI || settings.kind == .local { catalog.load(settings.snapshot()) }
        }
    }

    private func finish() {
        settings.didCompleteSetup = true
        isPresented = false
    }
}
