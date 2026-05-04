# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is hey-clawd

A macOS desktop pet (crab character) that reacts to AI coding sessions in real time. It integrates with Claude Code, Codex CLI, Cursor, Gemini CLI, Copilot CLI, and CodeBuddy via hooks and file monitoring, showing animated states (idle, thinking, working, error, etc.) based on tool activity. It also handles permission approvals for Claude Code and CodeBuddy tool use via floating bubbles.

## Build & Run

```bash
# Build (SPM)
swift build
swift build -c release

# Build (Xcode — used by CI)
xcodebuild -project hey-clawd.xcodeproj -scheme hey-clawd -configuration Release archive

# Run the built executable
.build/debug/hey-clawd

# Swift tests (SVG pipeline, HTTP server, Codex monitor, state-machine animation)
swift test

# Permission bubble integration tests
./test-bubble.sh all        # all test cases
./test-bubble.sh single     # single permission request
./test-bubble.sh stack      # concurrent bubble stacking
./test-bubble.sh passthrough # auto-allow passthrough tools
./test-bubble.sh disconnect  # client disconnect cleanup
./test-bubble.sh dnd         # do-not-disturb mode

# SVG animation visual smoke test (exercises /debug/svg on a running app)
./test-animations.sh

# Hook-side Node tests
cd hooks && node test/index.js
```

`Tests/HeyClawdAppTests/` covers SVG parsing/rendering (`SVGParserTests`, `CALayerRendererTests`, `CAAnimationBuilderTests`, `SVGBaselineScreenshotTests`), the HTTP server, Codex monitor, state-machine animation, and the full `PetView` pipeline. Permission-bubble and end-to-end UX paths are still validated via `test-bubble.sh` plus manual verification.

## Architecture

### Swift App (`Sources/`)

The app is a **menu-bar-only macOS app** (`LSUIElement=true`) built with Swift 6.0 and SPM. Single external dependency: Sparkle (auto-update). The pet is rendered with a custom Core Animation–based SVG pipeline — no WebView.

**Module layout:**

- **App/** — `HeyClawdApp` (@main SwiftUI entry) → `AppDelegate` (orchestrator). `AppDelegate.assembleCoreLoop()` wires all subsystems together.
- **Core/** — `StateMachine` (priority-based state aggregation across sessions), `HTTPServer` + `HTTPParser` (localhost:23333, endpoints: `/state`, `/permission`, `/status`, `/quit`, and `/debug/svg` + `/debug/reset`), `CodexMonitor` (kqueue-based JSONL log watcher for Codex CLI), `HookInstaller` (runs bundled JS install scripts via Node.js to register hooks on launch), `HotKeyManager`, `Preferences` (UserDefaults wrapper), `Session`, `SoundPlayer`.
- **Core/SVG/** — rendering pipeline: `SVGParser`, `SVGDocument` (+ LRU `SVGDocumentCache`), `CSSParser`, `ColorParser`, `PathParser`, `TransformParser`, `CALayerRenderer` (vector → CALayer tree), `CAAnimationBuilder` (CSS keyframes → Core Animation).
- **Window/** — `PetWindow` (transparent floating NSWindow), `PetView` (Core Animation host view that drives the SVG pipeline), `EyeTracker` (mouse-following eyes at 10 Hz, paused when the window is occluded or hidden).
- **Bubble/** — `BubbleStack` (async permission request queue with `CheckedContinuation`), `BubbleView`/`BubbleWindow` (SwiftUI overlay). Passthrough tools (TaskCreate, TaskUpdate, etc.) auto-allow without UI.
- **Tray/** — `StatusBarController` + `MenuBuilder` (system tray menu with session list, preferences, manual hook re-registration).
- **Mini/** — `MiniMode` (edge-hugging compact mode with peek/crabwalk animations).
- **Focus/** — `TerminalFocus` helper for focus-session UI.
- **Update/** — `SparkleUpdater` (Sparkle wrapper, enabled only in release builds via `ClawdEnableSparkleUpdater` plist key).

**Key data flow:**

```
IDE hooks / CodexMonitor → HTTP POST /state → HTTPServer → StateMachine → PetView (Core Animation)
IDE hooks → HTTP POST /permission → HTTPServer → BubbleStack → allow/deny response
```

### Hooks (`hooks/`) and Agents (`agents/`)

`hooks/` ships the Node/CommonJS handlers that get installed into IDE/CLI config dirs: `clawd-hook.js` (Claude Code), `gemini-hook.js`, `cursor-hook.js`, `codebuddy-hook.js`, `copilot-hook.js`, plus `codex-remote-monitor.js` for Codex. Each hook maps lifecycle events (PreToolUse, PostToolUse, SubagentStart, etc.) to pet states and posts them to the local HTTP server.

`server-config.js` handles port discovery: tries `~/.clawd/runtime.json` first, then scans ports 23333–23337.

**Auto-registration:** On launch, `HookInstaller` waits for `HTTPServer` to bind a port, then runs the installer scripts (`install.js`, `gemini-install.js`, `cursor-install.js`, `codebuddy-install.js`) via Node.js with `--port` to ensure the PermissionRequest HTTP hook URL matches the actual server port. Scripts skip tools that aren't installed. A manual "Register Hooks" menu item is also available for re-registration (e.g. after `cc-switch` profile changes).

`agents/` holds per-integration metadata and log-monitor helpers (`claude-code.js`, `codex.js`, `codebuddy.js`, `gemini-cli.js`, `cursor-agent.js`, `copilot-cli.js`, plus `codex-log-monitor.js` / `gemini-log-monitor.js` and a `registry.js` index). Keep event mappings in sync whenever a hook script, agent descriptor, installer allowlist, or `docs/integrations/` page encodes the same behavior.

### Pet States

States are declared by the `PetState` enum in `StateMachine.swift` with priority levels 0–8 — higher priority states override lower ones. One-shot states (attention, error, notification, etc.) play once then revert. Sleep sequence: yawning → dozing → collapsing → sleeping → waking. Mini-mode has its own `mini-*` state family. Each state maps to `Resources/svg/clawd-<state>.svg`.

### SVG Animations (`Resources/svg/`)

Each state has a corresponding `clawd-*.svg` file, parsed once and cached in `SVGDocumentCache`, then rendered as a CALayer tree with Core Animation keyframes. See `docs/svg-animation-spec.md` for the animation, pixel-grid, and color-palette spec, and `docs/rendering-system.md` for the renderer deep-dive.

## Release Process

Tag with `v*` (e.g., `git tag v1.2.3`) and push. GitHub Actions (`.github/workflows/release.yml`) builds, signs with Sparkle EdDSA, creates a GitHub Release, and publishes `appcast.xml` to the `gh-pages` branch (served via GitHub Pages) for the auto-update feed.

## Conventions

- All UI code is `@MainActor`. `StateMachine` and `CodexMonitor` are Swift actors.
- Async permission handling uses `CheckedContinuation` — never block the main thread.
- The app uses `@preconcurrency import Network` for strict concurrency compliance.
- SVGs use a 15×16 pixel character grid; body color `#DE886D`, effects cyan/gold/red.
- Supporting resources: `docs/` (integration notes + renderer deep-dive), `scripts/` (maintenance helpers such as `svg-audit-scan.js`).
- Upstream reference code lives in `references/` (gitignored) — `clawd-on-desk` is the Electron-based original.
