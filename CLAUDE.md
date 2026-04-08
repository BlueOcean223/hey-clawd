# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is hey-clawd

A macOS desktop pet (crab character) that reacts to AI coding sessions in real time. It integrates with Claude Code, Codex CLI, Cursor, Gemini CLI, and Copilot CLI via hooks and file monitoring, showing animated states (idle, thinking, working, error, etc.) based on tool activity. It also handles permission approvals for Claude Code tool use via floating bubbles.

## Build & Run

```bash
# Build (SPM)
swift build
swift build -c release

# Build (Xcode — used by CI)
xcodebuild -project hey-clawd.xcodeproj -scheme hey-clawd -configuration Release archive

# Run the built executable
.build/debug/hey-clawd

# Run permission bubble integration tests
./test-bubble.sh all        # all test cases
./test-bubble.sh single     # single permission request
./test-bubble.sh stack      # concurrent bubble stacking
./test-bubble.sh passthrough # auto-allow passthrough tools
./test-bubble.sh disconnect  # client disconnect cleanup
./test-bubble.sh dnd         # do-not-disturb mode

# Run hook unit tests
cd hooks && node test/codex-remote-monitor.test.js
```

There are no Swift unit tests — the app is integration-tested via `test-bubble.sh` and manual verification.

## Architecture

### Swift App (`Sources/`)

The app is a **menu-bar-only macOS app** (`LSUIElement=true`) built with Swift 6.0 and SPM. Single external dependency: Sparkle (auto-update).

**Module layout:**

- **App/** — `HeyClawdApp` (@main SwiftUI entry) → `AppDelegate` (orchestrator). `AppDelegate.assembleCoreLoop()` wires all subsystems together.
- **Core/** — `StateMachine` (priority-based state aggregation across sessions), `HTTPServer` (localhost:23333, endpoints: `/state`, `/permission`, `/status`, `/quit`), `CodexMonitor` (kqueue-based JSONL log watcher for Codex CLI), `HookInstaller` (runs bundled JS install scripts via Node.js to register hooks on launch), `HotKeyManager`, `Preferences` (UserDefaults wrapper), `SoundPlayer`.
- **Window/** — `PetWindow` (transparent floating NSWindow), `PetWebView` (WKWebView SVG renderer), `EyeTracker` (mouse-following eyes).
- **Bubble/** — `BubbleStack` (async permission request queue with `CheckedContinuation`), `BubbleView`/`BubbleWindow` (SwiftUI overlay). Passthrough tools (TaskCreate, TaskUpdate, etc.) auto-allow without UI.
- **Tray/** — `StatusBarController` + `MenuBuilder` (system tray menu with session list, preferences).
- **Mini/** — `MiniMode` (edge-hugging compact mode with peek/crabwalk animations).
- **Update/** — `SparkleUpdater` (Sparkle wrapper, enabled only in release builds via `ClawdEnableSparkleUpdater` plist key).

**Key data flow:**

```
IDE hooks / CodexMonitor → HTTP POST /state → HTTPServer → StateMachine → PetWebView (SVG animation)
IDE hooks → HTTP POST /permission → HTTPServer → BubbleStack → allow/deny response
```

### Hooks (`hooks/`)

JavaScript modules installed into IDE/CLI config dirs. `clawd-hook.js` is the primary Claude Code hook — it maps lifecycle events (PreToolUse, PostToolUse, SubagentStart, etc.) to pet states and posts them to the local HTTP server.

`server-config.js` handles port discovery: tries `~/.clawd/runtime.json` first, then scans ports 23333–23337.

**Auto-registration:** On launch, `HookInstaller` waits for `HTTPServer` to bind a port, then runs all four install scripts (`install.js`, `gemini-install.js`, `cursor-install.js`, `codebuddy-install.js`) via Node.js with `--port` to ensure the PermissionRequest HTTP hook URL matches the actual server port. Scripts skip tools that aren't installed. A manual "Register Hooks" menu item is also available for re-registration (e.g. after `cc-switch` profile changes).

### Pet States

27 states defined in `StateMachine.swift` with priority levels 0–8. Higher priority states override lower ones. One-shot states (attention, error, notification, etc.) play once then revert. Sleep sequence: yawning → dozing → collapsing → sleeping → waking.

### SVG Animations (`Resources/svg/`)

Each state has a corresponding `clawd-*.svg` file. See `Resources/SVG-ANIMATION-SPEC.md` for the pixel grid spec, color palette, and layering conventions used when creating/modifying animations.

## Release Process

Tag with `v*` (e.g., `git tag v1.2.3`) and push. GitHub Actions (`.github/workflows/release.yml`) builds, signs with Sparkle EdDSA, creates a GitHub Release, and commits `appcast.xml` back to `main` for the auto-update feed.

## Conventions

- All UI code is `@MainActor`. `StateMachine` and `CodexMonitor` are Swift actors.
- Async permission handling uses `CheckedContinuation` — never block the main thread.
- The app uses `@preconcurrency import Network` for strict concurrency compliance.
- SVGs use a 15×16 pixel character grid; body color `#DE886D`, effects cyan/gold/red.
- Upstream reference code lives in `references/` (gitignored) — `clawd-on-desk` is the Electron-based original.
