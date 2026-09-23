# Vibe Translate

A macOS translation app with the shape everyone already knows — two language
pickers, type on the left, read on the right — that can point at **a model
running on your own machine** instead of someone else's server.

- Google-Translate-style flow: `Lang A → input` / `Lang B → output`
- Four interchangeable backends: the free Google endpoint, OpenAI API, ChatGPT subscription, or any
  OpenAI-compatible local server (llama.cpp, LM Studio, Ollama, Jan)
- Provider setup on first launch, so a local model is wired up *before* the
  first translation instead of after a confusing failure
- Editable prompts — the system prompt and user message a local model receives
  are yours to change, with live substitution preview
- Every request runs off the main thread, streams as it generates, and is
  cancelled the moment you type again
- Universal binary (Apple Silicon + Intel), macOS 13 or later

## Build

```sh
git clone git@github.com:suicvne/vibe-translate.git
cd vibe-translate
./build.sh
```

Produces an ad-hoc signed universal app at `build/Vibe Translate.app`.
Requires the Swift toolchain from Xcode or the Command Line Tools — there is no
Xcode project and no package dependencies.

Version numbers come from the environment, so a release is one variable:

```sh
VERSION=1.1 ./build.sh
```

`CFBundleVersion` is derived from the git commit count.

The app icon is generated code rather than a checked-in asset. After editing
`Tools/MakeIcon.swift`, regenerate it with `./make-icon.sh`.

The focused ChatGPT provider check runs on macOS with
`bash Tests/run-chatgpt-provider.sh`. It mocks device authorization and checks
the Codex request and response format without contacting OpenAI or using a real
account.

## Run

```sh
open "build/Vibe Translate.app"
```

Type on the left. It translates as you type; `⌘↩` forces it immediately, `⌘⇧S`
swaps the two languages, `⌘,` opens Settings, `⌘⇧P` reopens provider setup.

## Backends

First launch opens the setup sheet. Pick one:

| Backend | Needs | Notes |
| --- | --- | --- |
| **Google (free endpoint)** | nothing | The undocumented endpoint the translate web page uses. Zero setup, and no guarantee it keeps working — it is not a supported API. Your text leaves the machine. |
| **OpenAI** | API key | `api.openai.com`, chat completions. The key is stored in your login keychain, not in preferences. |
| **ChatGPT subscription** | ChatGPT sign-in | Browser device sign-in, then the Codex Responses endpoint. Tokens are stored in the login keychain. No Codex CLI installation or API key is needed. This endpoint is not a public OpenAI API and may change. |
| **Local model** | a server | Any OpenAI-compatible server you are running. Nothing leaves the machine. |

For ChatGPT, select **ChatGPT subscription**, click **Sign in with ChatGPT**, and
enter the displayed code in the browser page. The app uses the subscription
model `gpt-5.5`. API-key OpenAI and OpenAI-compatible local servers remain
separate choices. Subscription use is subject to the limits of your ChatGPT
plan; it does not use API credits.

**Connect** asks the server for its model list (`GET /v1/models`) and fills the
model menu, so you find out the endpoint is wrong while you are configuring it
rather than mid-translation. Presets cover the usual ports:

| Server | Endpoint |
| --- | --- |
| llama.cpp | `http://127.0.0.1:8080/v1` |
| LM Studio | `http://127.0.0.1:1234/v1` |
| Ollama | `http://127.0.0.1:11434/v1` |
| Jan | `http://127.0.0.1:1337/v1` |

Local servers speak plain HTTP, which App Transport Security blocks by default.
The build declares `NSAllowsLocalNetworking`, which permits loopback and LAN
hosts without opening up arbitrary cleartext connections.

## Prompts

Settings ▸ Prompts edits exactly what a chat model receives. A 7B model that
rambles, refuses, or explains itself usually needs a firmer prompt rather than a
different app, and that is a thing you should be able to fix without a rebuild.

Placeholders, substituted per request:

| Placeholder | Becomes |
| --- | --- |
| `{source}` / `{target}` | English language names — `German`, `Japanese` |
| `{source_code}` / `{target_code}` | the raw codes — `de`, `ja` |
| `{text}` | the input text (user message only) |

"Show filled preview" renders the exact strings the model will be sent. If a
user template omits `{text}`, the input is appended rather than silently
dropped.

Settings ▸ Behaviour covers translate-as-you-type, response streaming,
temperature, and the request timeout — a large model on a cold start can take a
minute before the first token.

Local reasoning models that emit `<think>…</think>` are handled: the block is
hidden while streaming and stripped from the result, as are the quotation marks
chat models like to wrap a one-line translation in.

## Architecture

Adding a backend means one file. `TranslationProvider` is the whole contract —
a display name, whether a key is required, and an `async` `translate`:

| Type | Does |
| --- | --- |
| `TranslationProvider` | the protocol every backend implements |
| `OpenAICompatibleProvider` | everything `/chat/completions`: prompts, transport, streaming, model listing, cleanup |
| `OpenAIProvider` / `LocalOpenAIProvider` | subclasses supplying a base URL and whether a key is mandatory |
| `GoogleFreeProvider` | standalone; the endpoint is nothing like a chat API |
| `ChatGPTAuth` / `ChatGPTProvider` | native device sign-in and Codex Responses streaming |
| `ProviderSettings` | UserDefaults, plus the keychain for the API key |
| `TranslationService` | picks the backend for the current configuration |

Two decisions are load-bearing:

**Config is a value snapshot.** A provider is built around an immutable
`ProviderConfig` and is `Sendable` by construction, so it needs no locking and a
request already in flight cannot be changed out from under itself when you edit
a field mid-translation.

**Failures are reported, not swallowed.** A failure becomes a `TranslationError`
carrying the server's own message — "Could not reach 127.0.0.1. Is the server
running?" is the whole point of the status bar. Returning the input text
unchanged would leave you staring at a box wondering whether the model is slow,
broken, or simply thinks your sentence needed no translating.

## Installing (read this before sending it to someone)

This app is **ad-hoc signed**, not signed with an Apple Developer ID and not
notarized. macOS treats a downloaded copy as untrusted, and the first launch
fails with *"Vibe Translate is damaged and can't be opened"* — which only means
"Apple has never seen this binary."

The reliable fix, after moving the app to `/Applications`:

```sh
xattr -dr com.apple.quarantine "/Applications/Vibe Translate.app"
```

A copy transferred without going through a browser (AirDrop from your own Mac,
`scp`, a USB stick) usually skips this entirely.

## Releasing

```sh
VERSION=1.1 ./release.sh
```

Writes `dist/VibeTranslate-1.1.zip` plus a `.sha256`. It zips with `ditto`,
which preserves the code signature — a plain `zip` does not.

## License

MIT — see [LICENSE](LICENSE). Copyright © 2026 Mike Santiago.
