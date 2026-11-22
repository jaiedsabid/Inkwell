# Inkwell

A menu bar app that checks your writing in every Mac app (browsers, Slack, Mail, Notes and more), with inline
suggestions and a chat panel for rewriting selected text.

- **Red wavy line**: spelling or grammar mistake. Hover to see the fix, click Accept to apply it.
- **Blue line**: the whole sentence could be clearer. Hover to see a better version.
- **⌥ Space** (configurable): with text selected, opens a chat panel. Ask for a change, refine it as many times as
  you like, then Accept to put it back. With nothing selected, it writes new text at the cursor.
- **Purple dashed line**: the sentence doesn't fit your tone (optional).
- **Menu bar icon**: turn Inkwell on or off everywhere, pause it, switch it off for the current app or website,
  change tone or language, and see today's stats.

## Features

| Area | What you get |
|---|---|
| Checking | Spelling (offline), grammar, clearer sentences, tone check; relaxed / standard / picky; a short "why" under each fix |
| Fixing | Accept, Dismiss, Fix all, Undo, Add to dictionary |
| Chat panel | Free-form prompts and refinements; quick actions (Fix grammar, Shorter, Longer, Simpler, Friendlier, Professional, Confident); Translate; Draft a reply; your own saved prompts |
| Writing | Main language with auto-detection, default tone plus a tone per app |
| Control | On/off everywhere, pause (30 min, 1 hour, until tomorrow), off per app or website; password managers and terminals off by default; password fields never read |
| AI | Anthropic or OpenAI with your own key (Keychain), or Apple's on-device model (macOS 26+) |
| Stats | Words written, fixes, rewrites, accept rate, common mistakes, apps; today / 7 days / 30 days with trends. Counts only, stored locally |

## How it works

- Reads the focused text field through the macOS Accessibility API (needs Accessibility permission). Password
  fields are never read. Chromium and Electron apps (Chrome, Slack, Discord, VS Code…) are asked to expose their
  text with `AXManualAccessibility` / `AXEnhancedUserInterface`.
- Spelling is checked instantly and offline with the macOS spell checker. Grammar, clarity and rewrites go to an AI:
  Anthropic or OpenAI with your own key (stored in the Keychain), or Apple's on-device model on macOS 26+.
- AI results are cached per sentence, so editing one sentence only re-checks that sentence.
- Underlines are drawn in transparent, click-through windows over the app. When an app doesn't report where words
  are on screen, a count badge appears at the field's corner instead.
- Replacements use Accessibility first and fall back to select + paste (the clipboard is restored afterwards).

Because it needs Accessibility access, Inkwell can't be sandboxed, so it's distributed outside the Mac App Store.

## Build

Needs only the Command Line Tools (no Xcode). macOS 15 or later.

```bash
./build.sh                       # dist/Inkwell.app and dist/Inkwell.dmg
SKIP_DMG=1 ./build.sh            # app only
.build/release/Inkwell --selftest
.build/debug/Inkwell --snapshot /tmp/inkwell-shots   # renders the main screens to PNG
```

Run `scripts/signing_identity.sh create` once so every build has the same signature; otherwise macOS asks for
Accessibility again after each build.
