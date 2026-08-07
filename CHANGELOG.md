# Changelog

Newest first. [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
semantic versioning.

## [0.1.0] - 2026-08-07

First release.

### Added
- Phone notifications when a coding agent finishes a turn or needs input, for
  Claude Code, Codex CLI, Cursor, Gemini CLI and Copilot CLI.
- Transports: ntfy (hosted and self-hosted), Pushover, Telegram, Gotify,
  Discord, Slack, a raw JSON webhook, and a `cmd://` escape hatch.
- An additive desktop banner on macOS, Linux, Windows and WSL, skipped
  automatically over SSH and in CI.
- Noise gates: a minimum turn duration, per-session debounce, quiet hours and
  `snooze`, with permission prompts deliberately exempt from all but `snooze`.
- `setup`, `install`, `uninstall`, `test`, `status`, `doctor`, `snooze`, `send`.
- `setup` asks for the destination, the minimum turn length and quiet hours,
  then offers to wire up the agents it found. Enter takes the default, and with
  no terminal, or under `-y`, it asks nothing and wires nothing.
- A Claude Code plugin, so no one has to hand-edit `settings.json`. It is the
  recommended path for Claude Code; `ntfy-agent install` covers the rest.

Windows runs under Git Bash or WSL, which is where Claude Code puts its own
hooks there.

`gotify://` accepts both `<token>@<host>` and Apprise's `<host>/<token>`.
