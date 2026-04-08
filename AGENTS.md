# Repository Guidelines

## Project Structure & Module Organization
`Sources/` contains the macOS app, split by responsibility: `App/` for startup and wiring, `Core/` for state, server, preferences, and monitors, `Window/` for the floating pet UI, `Bubble/` for permission prompts, `Tray/` for menu bar controls, `Mini/` for compact mode, and `Update/` for Sparkle. `Resources/` holds SVG animations, sounds, and the web bridge used by `WKWebView`. `hooks/` contains Node-based integrations for Claude Code, Codex, Cursor, Gemini, and Copilot, plus tests under `hooks/test/`. `docs/` captures repo-specific integration notes.

## Build, Test, and Development Commands
Use `swift build` for the default debug build and `.build/debug/hey-clawd` to run it. Use `swift build -c release` for a local release build. CI archives with `xcodebuild -project hey-clawd.xcodeproj -scheme hey-clawd -configuration Release archive`, so keep that path healthy when changing packaging or signing behavior. Run `./test-bubble.sh all` for permission-bubble integration checks, or swap `all` for `single`, `stack`, `passthrough`, `disconnect`, or `dnd`. Run `cd hooks && node test/codex-remote-monitor.test.js` for the existing Node hook tests.

## Coding Style & Naming Conventions
Follow the existing Swift style: 4-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for methods and properties, and one primary type per file named after that type, such as `StateMachine.swift`. Keep UI work on `@MainActor`; long-lived coordination belongs in actors like `StateMachine` and `CodexMonitor`. In `hooks/`, stay with CommonJS, double quotes, and small single-purpose modules. Name SVG assets with the existing `clawd-<state>.svg` pattern.

## Testing Guidelines
This repo does not currently use Swift unit tests. Validate app changes with `./test-bubble.sh` and manual behavior checks in the menu bar app. Add or update Node tests in `hooks/test/` when changing JSONL parsing or hook event mapping. Keep test files named `*.test.js` and cover event sequencing, stale cleanup, and port discovery when relevant.

## Commit & Pull Request Guidelines
Recent history uses Conventional Commit prefixes like `feat:`, `fix:`, `refactor:`, and `art:`. Keep subjects short and action-oriented. Pull requests should explain the user-visible behavior change, list the commands you ran, and attach screenshots or GIFs for pet, tray, bubble, or SVG changes. Link the related issue when there is one, and call out release-impacting edits to `Info.plist`, Sparkle setup, or `.github/workflows/release.yml`.
