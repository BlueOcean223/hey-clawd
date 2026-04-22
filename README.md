<h1 align="center">hey-clawd</h1>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a></p>

<p align="center">
  <img src="Resources/gif/clawd-thinking.gif" width="120" alt="thinking" />
  <img src="Resources/gif/clawd-build.gif" width="120" alt="building" />
  <img src="Resources/gif/clawd-wizard.gif" width="120" alt="wizard" />
  <img src="Resources/gif/clawd-music.gif" width="120" alt="music" />
  <img src="Resources/gif/clawd-dump.gif" width="120" alt="dump" />
</p>

A macOS menu-bar desktop pet — Clawd reacts in real time to what your AI coding assistant is doing. It integrates with Claude Code, Codex CLI, Cursor, Gemini CLI, GitHub Copilot CLI, CodeBuddy and Pi, and plays different animations for idle / thinking / working / error / sleep states. For Claude Code and CodeBuddy it can also surface tool-use permission prompts as floating bubbles so you never have to return to the terminal just to click "allow".

## Highlights

- **Reacts to 7 AI coding tools** — Claude Code, CodeBuddy, Cursor, Gemini CLI, Copilot CLI via hooks; Pi via extension; Codex CLI via JSONL log monitoring.
- **Permission bubbles** — approve or deny tool use for Claude Code / CodeBuddy without leaving your editor; passthrough tools (`TaskCreate`, `TaskUpdate`, …) auto-allow.
- **Custom Core Animation SVG pipeline** — no WebView. 50+ hand-drawn states on a 15×16 pixel grid, cached via LRU.
- **Lightweight & native** — Swift 6 + AppKit/Core Animation. No WebView, no embedded JS runtime. Low CPU and memory footprint.
- **Menu-bar only** (`LSUIElement`) with mini edge-hugging mode, eye tracking that follows your cursor, and a Do-Not-Disturb toggle.
- **Auto-updating** via Sparkle (EdDSA-signed appcast).
- **Single external dependency**: Sparkle. Everything else is Swift 6 + stdlib.

## Requirements

- macOS 12 (Monterey) or newer
- Node.js (for bundled installers to register hooks/extensions into Claude Code / Cursor / Gemini / CodeBuddy / Pi on first launch)

## Install

### Download the release

Grab the latest `.dmg` from [GitHub Releases](https://github.com/BlueOcean223/hey-clawd/releases), drag **hey-clawd.app** into `/Applications`, and launch. The app lives in the menu bar — right-click the Clawd icon to open the tray menu.

On first launch it starts a local HTTP server on `127.0.0.1:23333` (falls back to 23334–23337) and runs the bundled installers to register hooks/extensions into any detected AI tools. Tools that aren't installed are skipped. You can re-run registration anytime from the tray menu → **Register Hooks**.

### Build from source

```bash
# Swift Package Manager (debug)
swift build
.build/debug/hey-clawd

# Release build
swift build -c release

# Xcode (matches CI)
xcodebuild -project hey-clawd.xcodeproj -scheme hey-clawd -configuration Release archive
```

## Supported integrations

| Tool | Method | Direction | Permission bubble | Terminal focus |
|------|--------|-----------|:-----------------:|:--------------:|
| Claude Code  | hook           | bidirectional | ✅ | ✅ |
| CodeBuddy    | hook           | bidirectional | ✅ | ✅ |
| Gemini CLI   | hook           | one-way       | — | ✅ |
| Cursor       | hook           | one-way       | — | ✅ |
| Copilot CLI  | hook           | one-way       | — | ✅ |
| Codex CLI    | JSONL monitor  | read-only     | — | — |
| Pi           | extension      | one-way       | — | ✅ |

See [docs/integrations/platform-comparison.md](docs/integrations/platform-comparison.md) for the full event-coverage matrix and per-tool deep dives in [docs/integrations/](docs/integrations/).

## How it works

```
IDE hooks / Pi extension / CodexMonitor  →  HTTP POST /state  →  HTTPServer  →  StateMachine  →  PetView (Core Animation)
IDE hooks                                →  HTTP POST /permission  →  HTTPServer  →  BubbleStack  →  allow/deny
```

- **StateMachine** — priority-based aggregator (priority 0–8) across concurrent sessions. Higher-priority states override lower ones; one-shot states (attention, error, notification) play once then revert.
- **SVG pipeline** — `SVGParser` → `SVGDocument` (LRU cache) → `CALayerRenderer` → `CAAnimationBuilder` (CSS keyframes → Core Animation). See [docs/rendering-system.md](docs/rendering-system.md).
- **Integration bridge** (`hooks/`) — CommonJS hook handlers (`clawd-hook.js`, `cursor-hook.js`, `gemini-hook.js`, `codebuddy-hook.js`, `copilot-hook.js`), the Codex JSONL monitor (`codex-remote-monitor.js`), plus the Pi extension/installer pair (`pi-extension.ts`, `pi-install.js`). Each integration ultimately maps tool lifecycle events to pet states and POSTs to the local HTTP server. Port discovery: `~/.clawd/runtime.json` first, then scans 23333–23337.
- **HTTP endpoints** — `/state`, `/permission`, `/status`, `/quit`, plus `/debug/svg` and `/debug/reset` for development.

## State gallery

A peek at the raw SVG states. These are CSS-animated and rendered natively by the Core Animation pipeline at runtime — what you see in GitHub is the exact same source file the app consumes.

| Idle | Typing | Thinking | Wizard | Happy |
|:---:|:---:|:---:|:---:|:---:|
| <img src="Resources/svg/clawd-idle-living.svg" width="100" alt="idle" /> | <img src="Resources/svg/clawd-working-typing.svg" width="100" alt="typing" /> | <img src="Resources/svg/clawd-working-thinking.svg" width="100" alt="thinking" /> | <img src="Resources/svg/clawd-working-wizard.svg" width="100" alt="wizard" /> | <img src="Resources/svg/clawd-happy.svg" width="100" alt="happy" /> |
| `idle-living` | `working-typing` | `working-thinking` | `working-wizard` | `happy` |

| Smoking | Reading | Music | Dozing | Sleeping |
|:---:|:---:|:---:|:---:|:---:|
| <img src="Resources/svg/clawd-idle-smoking.svg" width="100" alt="smoking" /> | <img src="Resources/svg/clawd-idle-reading.svg" width="100" alt="reading" /> | <img src="Resources/svg/clawd-idle-music.svg" width="100" alt="music" /> | <img src="Resources/svg/clawd-idle-doze.svg" width="100" alt="doze" /> | <img src="Resources/svg/clawd-sleeping.svg" width="100" alt="sleeping" /> |
| `idle-smoking` | `idle-reading` | `idle-music` | `idle-doze` | `sleeping` |

Full catalog of 50+ states: [docs/svg-catalog.md](docs/svg-catalog.md).

## Develop

```bash
# Swift test target (SVG parsing/rendering, HTTP server, Codex monitor, state machine)
swift test

# Permission-bubble integration tests (hits a running app)
./test-bubble.sh all         # or: single | stack | passthrough | disconnect | dnd

# SVG animation visual smoke test (hits /debug/svg on a running app)
./test-animations.sh

# Hook-side Node tests
cd hooks && node test/pi-install.test.js && node test/codex-remote-monitor.test.js && node test/hook-cleanup.test.js
```

Further docs:

- [docs/svg-catalog.md](docs/svg-catalog.md) — every `PetState` → SVG mapping.
- [docs/svg-animation-spec.md](docs/svg-animation-spec.md) — SVG animation, pixel-grid, and palette spec.


## License

[MIT](LICENSE) — retains the original copyright from `clawd-on-desk`.

## Acknowledgements

- Form and architecture derived from [@rullerzhou-afk](https://github.com/rullerzhou-afk)'s [clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk).
- Some art direction and animation inspiration was also referenced from [@marciogranzotto](https://github.com/marciogranzotto)'s [clawd-tank](https://github.com/marciogranzotto/clawd-tank). Thank you for the lovely Clawd worldbuilding and pixel-art ideas.
- Shared with the [LINUX DO](https://linux.do/) community.
