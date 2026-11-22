# Changelog

All notable changes to Inkwell are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Automatic updates** with [Sparkle](https://sparkle-project.org): Inkwell checks once a day and asks before installing; Settings → General has Check for Updates… and a switch for automatic checks. Updates are signed and verified, and settings and the Accessibility permission are kept.
- The app now lists its copyright and category (Productivity).

## [0.1.1] - 2026-11-23

### Fixed

- The diagnostic log no longer records flagged words; logs from 0.1.0 are deleted on first launch.
- Idle CPU use drops from about 6% to under 1% (state that didn't change no longer redraws every view four times a second).
- VoiceOver names every switch and button in the menu bar panel, the Improve panel and the suggestion card, and skips decorative icons.

### Added

- A warning when the Improve shortcut is taken, or when an app that often uses ⌥ Space (Alfred, ChatGPT, Raycast, Claude) is running, with a quick way to pick another; Inkwell takes the shortcut back if the other app quits.
- Onboarding mentions Tab suggestions and offers "Open Inkwell when I log in" (on by default, easy to untick).
- README: what to do when the menu bar icon is hidden by the notch, and how to uninstall.

## [0.1.0] - 2026-11-22

### Added

- **Checks in every app.** Spelling, grammar, punctuation, capitalization, clearer sentences and an optional tone check in Mail, Slack, Notes, browsers, Google Docs, Notion and most other Mac apps, through the Accessibility API.
- **Suggestion card.** Hover an underline for the fix, the reason and the words around it. Accept, Ignore, Fix all, Undo, Add to dictionary, always ignore a suggestion, stop a kind of check, or turn Inkwell off for the app or website.
- **Instant offline checks.** Doubled words, a/an by sound, commonly confused words (its/it's, then/than, your/you're, could of), a lowercase "I", spacing around punctuation, a missing full stop or capital, commas after introductory words, and wordy phrases.
- **Improve selected text.** Select text, press ⌥ Space and ask for any change. Quick actions (Fix grammar, Shorter, Longer, Simpler, Friendlier, Professional, Confident), Translate, Draft a reply, your own saved prompts, and writing new text at the cursor.
- **Next-word suggestions.** Gray text after the cursor: Tab accepts, → takes one word, Esc dismisses. A word, a phrase or the rest of the sentence. Local models continue your text directly and keep only words they're sure of; macOS predictive text finishes half-typed words instantly.
- **Tones and languages.** Seven built-in tones, your own tones, a tone per app, 19 languages with automatic detection.
- **Choice of AI.** Free local models from Hugging Face (Gemma 4, Qwen 3.5, Llama 3.x or any GGUF) run by the bundled llama.cpp, with a recommendation for your Mac; Apple's on-device model on macOS 26; or your own key for Anthropic, OpenAI, Google Gemini, OpenRouter or Ollama. Keys are kept in the Keychain.
- **Menu bar panel.** On/off everywhere, pause, off for the current app or website, the tone there, default tone and language, and today's words, fixes and rewrites.
- **Writing stats.** Words, fixes, rewrites, accept rate, common mistakes and apps for today, 7 or 30 days. Counts only, stored on your Mac.
- **Custom shortcut** for Improve selected text, with ⌥ Space as the default.
- **Privacy defaults.** Password fields are never read; password managers and terminals are off by default; no analytics. Accepting a fix types the text instead of using the clipboard, and any paste is marked so clipboard managers skip it.
- Settings show in the Dock and ⌘Tab while open; the version is shown in Settings → General → About.

[Unreleased]: https://github.com/jaiedsabid/Inkwell/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/jaiedsabid/Inkwell/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jaiedsabid/Inkwell/releases/tag/v0.1.0
