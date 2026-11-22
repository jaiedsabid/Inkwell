# Developing Inkwell

How to build, run and test Inkwell, and how the code fits together.

## Requirements

- A Mac with Apple silicon on macOS 15 or later.
- The Command Line Tools (`xcode-select --install`). Xcode is not needed.
- Google Chrome, only to re-render the icons and README images.
- The GitHub CLI (`gh`), only to publish releases.

## Build and run

```bash
./build.sh                  # dist/Inkwell.app and dist/Inkwell.dmg (release build)
SKIP_DMG=1 ./build.sh       # the app only, faster
open dist/Inkwell.app
swift build                 # debug build in .build/debug, for the command-line tools below
```

`build.sh` does the following:

1. It runs `scripts/fetch_llama.sh`. That downloads the pinned llama.cpp framework (version and SHA-256 at the top of the script) into `Vendor/`, which is not committed.
2. It runs `swift build -c release`. SwiftPM also fetches Sparkle, pinned in `Package.swift` and `Package.resolved`.
3. It assembles `dist/Inkwell.app`: the binary, `llama.framework`, `Sparkle.framework` (without its XPC services, since the app isn't sandboxed), the icons, and an `Info.plist` written by the script. The version comes from `VERSION`, or from `INKWELL_VERSION` and `INKWELL_BUILD` when they're set.
4. It signs everything inside out (Sparkle's helpers, the frameworks, then the app) with the **Inkwell Signing** identity. If that identity doesn't exist, it signs ad hoc.
5. Unless `SKIP_DMG=1` is set, it makes `dist/Inkwell.dmg` with an Applications shortcut.

**Use the fixed signing identity.** With an ad hoc signature, macOS treats every build as a new app and asks for Accessibility again. Run `scripts/signing_identity.sh create` once on a new Mac, or import your backup of the identity.

After a rebuild, quit Inkwell and open `dist/Inkwell.app` again: `pkill -x Inkwell; open dist/Inkwell.app`.

## Command-line tools

The same binary has a few development modes. Run them from `.build/debug/Inkwell` or `dist/Inkwell.app/Contents/MacOS/Inkwell`; the bundled one is needed where it says so.

| Command | What it does |
|---|---|
| `--selftest` | Runs the built-in tests (rules, suggestions, parsing, settings). Prints `All passed` or the failures. Run it before every commit. |
| `--snapshot DIR` | Renders the main screens to PNG files in DIR: suggestion cards, the Improve panel, the menu, settings panes, onboarding and stats. Run it from the bundled app to get the real icon in the images. |
| `--localtest MODEL_ID` | Downloads a local model if needed (for example `gemma4-e2b`, `llama32-1b`), then runs a grammar check, a rewrite and about 20 realistic next-word cases through both suggestion paths. |
| `INKWELL_CHECK_TEXT="…" … --localtest MODEL_ID` | Checks your own text instead and prints the model's raw reply, to see why a suggestion appears. |
| `--aitest` | Runs a check and a rewrite against the AI engine set up in Settings. Cloud engines use your key and cost a little. |
| `--models PROVIDER` | Lists the models a provider offers with your key (`anthropic`, `openai`, `gemini`, `openrouter`, `ollama`). |

## Logs and settings

- **Diagnostic log:** `~/Library/Logs/Inkwell.log`. It records the app in front, the field type, issue counts and underline positions. It must never contain the user's text.
- **Settings:** `defaults read app.inkwell.mac`. Values are JSON-encoded, so string values appear as hex bytes.
- **Data:** `~/Library/Application Support/Inkwell`, holding `Models/` (downloaded GGUF files) and `stats.json`.
- **API keys:** login Keychain, service `app.inkwell.mac.apikey`, one item per provider.

## How the code fits together

All sources are in `Sources/Inkwell`.

| File | Role |
|---|---|
| `InkwellApp.swift` | App start-up, the command-line modes, the Settings and onboarding windows, and the Dock icon while a window is open. |
| `Coordinator.swift` | The heart. Polls the focused text field four times a second through Accessibility, feeds the text to the checker and the autocomplete, lays out underlines, and handles hover, accept, fix all and undo. |
| `AX.swift` | Accessibility helpers: focused element, value, selection, word bounds, secure-field and search-field detection, and the Chromium/Electron switches. |
| `Checker.swift` | Splits text into sentences and caches AI results per sentence. Merges spelling, local rules, punctuation rules and AI issues. Holds the AI check prompt and its parser, plus the guards that check an AI fix is real (kind check, doubled punctuation, closest spelling fix). |
| `Rules.swift` | Instant offline English rules: doubled words, a/an, confused words, spacing, intro commas, wordy phrases. |
| `Autocomplete.swift` | Next-word suggestions. With local models it continues the text directly and scores each word by probability; with cloud and Apple models it uses an instruction prompt. Also handles macOS word completions, the Tab, → and Esc key tap, and accepting. |
| `LlamaEngine.swift` | llama.cpp wrapper: loading models, chat formatting, grammar-constrained JSON, plain continuation with token healing, and reusing the prompt prefix between requests. |
| `AIEngine.swift` | Clients for Anthropic, OpenAI-compatible APIs (OpenAI, OpenRouter, Ollama), Gemini and Apple's on-device model. |
| `LocalModels.swift`, `LocalModelsView.swift` | The model catalog, downloads from Hugging Face, the memory-based recommendation, and the list UI. |
| `Replacer.swift` | Puts text into the other app: Accessibility first, then typed key presses for short text, then a paste marked transient so clipboard managers skip it. |
| `ChatPanel.swift` | The Improve selected text panel (⌥ Space). |
| `SuggestionCard.swift` | The hover card and its controller, which stays open while its ••• menu is in use. |
| `Overlay.swift` | Transparent click-through windows that draw the underlines and the gray suggestion text. |
| `MenuBar.swift`, `StatusMenu.swift` | The menu bar panel and the status item. |
| `SettingsView.swift`, `Settings.swift` | Settings UI and storage (`AppSettings`), including the shortcut recorder. |
| `Hotkey.swift` | The global shortcut (Carbon), and warnings when another app may hold it. |
| `AppUpdater.swift` | Sparkle updates. |
| `Onboarding.swift`, `Stats.swift`, `StatsView.swift`, `Models.swift`, `Log.swift`, `Keychain.swift`, `Loc.swift` | Onboarding, writing stats, shared types and theme, the log, Keychain access, and a small `@State` replacement. |
| `SelfTest.swift`, `Snapshot.swift` | `--selftest`, `--localtest`, `--aitest` and `--snapshot`. |

### Things to know

- **No `@State` in SwiftUI views.** The Command Line Tools have no SwiftUI macro plugin, so `@State` doesn't compile. Use `@Loc` (in `Loc.swift`) or an `ObservableObject` held with `@StateObject`.
- **Published state in the 4×-a-second loop.** In `Coordinator.tick()`, only assign a `@Published` property when the value really changes. Otherwise every view redraws four times a second and idle CPU rises from under 1% to about 6%.
- **The log never gets user text.** Log kinds, counts and positions only.
- **Small local models.** Llama 3.2 1B is too small for grammar checks and invents mistakes. Gemma 4 E2B is the recommended minimum. Next-word suggestions work well even with 1B.
- **Shortcut clashes.** macOS gives a global shortcut to whichever app registered it first and doesn't tell the other. `Hotkey.knownOptionSpaceApps` lists apps that commonly use ⌥ Space.

## Brand assets

- `brand/app-icon.svg` is the master icon. `brand/glyph-*.svg` are the glyphs, and `glyph-menubar.svg` is the menu bar template.
- `scripts/make_icons.sh` renders `Resources/AppIcon.icns`, `Resources/MenuIcon*.png` and `brand/app-icon-1024.png` with headless Chrome.
- `brand/brand-guide.html` covers colours, type, voice and usage.
- README images live in `images/`. The banner and hero image were rendered from HTML with headless Chrome; the other screenshots come from `--snapshot`.
