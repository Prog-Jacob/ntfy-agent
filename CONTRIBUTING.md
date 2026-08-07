# Contributing

```sh
sh test/test.sh                                       # no network, no framework
shellcheck -s sh bin/ntfy-agent install.sh test/test.sh
claude plugin validate ./                             # the manifests
```

CI runs those, then the suite under `sh` and `bash` on Linux and macOS, `dash`
on Linux, and Git Bash on Windows.

## The four constraints

**A hook must print nothing and always exit 0.** On Gemini CLI any code other
than 0 or 1 becomes `decision: "deny"`. Exit 2 also blocks on Claude Code's
`Stop` and `UserPromptSubmit`, on Cursor, and on Codex. One handler serves all of
them, so it holds to the strictest reading. A notifier that can deny your agent
is far worse than no notifier.

**Sending is detached.** A hung network call must never stall the agent, so
delivery re-execs into a separate process with a hard `NTFY_AGENT_TIMEOUT`
ceiling and no retry. A late notification is worthless anyway.

**Never parse a transcript.** Every agent with a turn-finished event also puts
the final assistant text in the hook payload, and Claude Code's docs warn the
transcript file lags. Reading the payload also avoids needing GNU or BSD `date`
to parse ISO timestamps, which is where portability usually dies.

**Agent output is hostile input.** The assistant's last message reaches HTTP
headers, a JSON body, an AppleScript literal and a PowerShell command. It is
flattened, escaped, and kept out of argv on every path. [SECURITY.md](SECURITY.md)
has the specifics.

## Adding things

Each agent's event is normalized to `done` or `needs_input` in `normalize()`,
and transports are written once against that pair.

- **A transport** is a `send_*` function plus a line in `send_url` and `SCHEMES`.
  About ten lines. Add a test against the `cmd://` sink or the fake-curl harness
  so the suite stays offline.
- **An agent** is a row in `agents()` and an `install_<id>` function.
- **A setting** goes in `conf_keys()` and the README table. CI fails if they
  disagree, and if `plugin.json` offers one that does not exist.

Bumping the version means changing it in `bin/ntfy-agent`,
`.claude-plugin/plugin.json` and `CHANGELOG.md`. CI checks all three match.
