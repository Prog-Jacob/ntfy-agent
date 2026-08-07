<h1 align="center">ntfy-agent</h1>

<p align="center">
  <b>Your coding agent finished, or it is stuck waiting on you. Your phone says so.</b>
</p>

<p align="center">
  <a href="https://github.com/Prog-Jacob/ntfy-agent/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Prog-Jacob/ntfy-agent/actions/workflows/ci.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="POSIX sh" src="https://img.shields.io/badge/shell-POSIX%20sh-lightgrey.svg">
</p>

```
🔔  Claude Code needs input · api-service@feat/auth
    Allow Bash(npm run migrate)?

✅  Claude Code finished · api-service@feat/auth (11m)
    Migration applied, 3 tables changed. Tests pass.
```

One POSIX shell script. No runtime, no daemon, no account, no signup.

Works with **Claude Code**, **Codex**, **Cursor**, **Gemini CLI** and **Copilot CLI**.
Delivers to **ntfy**, **Telegram**, **Pushover**, **Discord**, **Slack**, **Gotify**,
any webhook, or any shell command.

---

## Quick start

**1. Install**

```sh
curl -fsSL https://raw.githubusercontent.com/Prog-Jacob/ntfy-agent/main/install.sh | sh
```

It asks three questions, each with a default you can take by pressing Enter:
where to send, how short a turn to ignore, and whether to go quiet overnight.
Then it offers to wire up the agents it found. Add `-y` to take every default
without being asked.

**2. Subscribe your phone**

Install the ntfy app
([iOS](https://apps.apple.com/app/ntfy/id1625396347) ·
[Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy) ·
[F-Droid](https://f-droid.org/packages/io.heckel.ntfy/)),
tap **+**, and subscribe to the topic that was printed. No account needed.

**3. Check it**

```sh
ntfy-agent test        # your phone should buzz
```

Restart any agent session that was already running. Hooks load at startup.

> [!TIP]
> **Claude Code only?** Install the plugin instead. It carries the hooks with it,
> so nothing edits your `settings.json`:
>
> ```
> /plugin marketplace add Prog-Jacob/ntfy-agent
> /plugin install ntfy-agent@ntfy-agent
> ```
>
> Use the plugin **or** `ntfy-agent install`, never both.

<details>
<summary><b>Other ways to install</b></summary>

<br>

Without piping to `sh`:

```sh
curl -fsSL -o ~/.local/bin/ntfy-agent \
  https://raw.githubusercontent.com/Prog-Jacob/ntfy-agent/main/bin/ntfy-agent
chmod +x ~/.local/bin/ntfy-agent
ntfy-agent setup
```

Installer flags:

| Flag | Effect |
|---|---|
| `-b <dir>` | Install directory, instead of the first writable default |
| `-v <ref>` | Pin a git ref, instead of the latest release |
| `-y` | Accept defaults, never prompt (`NTFY_AGENT_YES=1` does the same for `setup`) |
| `-n` | Skip `setup`, so no config is written |
| `--uninstall` | Remove the script, hooks, config and state |

```sh
curl -fsSL .../install.sh | sh -s -- -v v0.1.0 -b /usr/local/bin
```

The Claude Code plugin, non-interactively:

```sh
claude plugin marketplace add Prog-Jacob/ntfy-agent
claude plugin install ntfy-agent@ntfy-agent --scope user
```

**Requirements.** `curl` is needed to send. `jq` is needed by `install` and
`uninstall` only, never on the notification path. **Windows** needs
[Git for Windows](https://gitforwindows.org) or WSL for `sh`; Claude Code already
prefers Git Bash for its own hooks.

</details>

## Supported agents

`ntfy-agent install` detects what you have, backs up every file it touches,
refuses to clobber a hook that is not ours, and `ntfy-agent uninstall` puts
things back.

| Agent | Finished turn | Needs your input | Turn duration |
|---|:---:|:---:|:---:|
| Claude Code | ✅ | ✅ | ✅ |
| Codex CLI | ✅ | not exposed by Codex | not exposed |
| Cursor | ✅ | not exposed by Cursor | ✅ |
| Gemini CLI | ✅ | ✅ | ✅ |
| Copilot CLI | ✅ | ✅ | ✅ |

Duration is what lets a notification say the turn took eleven minutes. Where it
is missing, every finished turn notifies regardless of length.

Verified end to end against Claude Code and Codex. The other three are built
from their documented hook schemas; reports welcome.

Anything else that can run a command on an event:

```sh
ntfy-agent hook generic done          # payload on stdin, or as the last argument
ntfy-agent hook generic needs_input
```

## Where notifications go

Set `NTFY_AGENT_URLS` in `~/.config/ntfy-agent/config`, or export it. Several at
once, comma separated. Then run `ntfy-agent test`.

| Service | Value | Where the credentials come from |
|---|---|---|
| **ntfy** | `ntfy://my-topic` | Any unguessable string. Subscribe the app to the same one. |
| ntfy, self-hosted | `ntfy://<token>@host/topic` | Your server. Use `ntfy+http://` for plain HTTP. |
| **Telegram** | `tgram://<bot-token>/<chat-id>` | [@BotFather](https://t.me/BotFather) → `/newbot`. Chat id: see below. |
| **Pushover** | `pover://<user-key>@<api-token>` | [pushover.net](https://pushover.net): key on the dashboard, token from a new Application. |
| **Discord** | `discord://<id>/<token>` | Server Settings → Integrations → Webhooks. The last two path segments of the URL. |
| **Slack** | `slack://T000/B000/xxx` | An [Incoming Webhook](https://api.slack.com/apps). The path after `/services/`. |
| **Gotify** | `gotify://<token>@host` | Your server: Apps → Create Application. |
| Any webhook | `https://example.com/hook` | Raw JSON POST of the event. |
| Anything else | `cmd://<command>` | Runs a shell command. |

A desktop banner also fires where you would see it: Notification Center on
macOS, `notify-send` on Linux, BurntToast on Windows and WSL. Skipped over SSH
and in CI.

> [!NOTE]
> Discord and Slack are log destinations, not alerts. Neither carries priority.
> Use ntfy or Pushover for anything you need to see.

<details>
<summary><b>Finding your Telegram chat id</b></summary>

<br>

A bot cannot start a conversation, so:

1. Send any message to your new bot.
2. Open `https://api.telegram.org/bot<your-token>/getUpdates`.
3. Find `"chat":{"id":987654321`. That number is the chat id.

```sh
NTFY_AGENT_URLS="tgram://123456789:AAExxxxxxxx/987654321"
```

</details>

<details>
<summary><b>Webhook payload, and the cmd:// environment</b></summary>

<br>

`https://` destinations receive:

```json
{"agent":"claude","event":"needs_input","project":"api@main","session":"abc",
 "cwd":"/src/api","elapsed":671,"title":"...","body":"...","click":""}
```

`cmd://` runs a shell command with `NTFY_TITLE`, `NTFY_BODY`, `NTFY_PRIORITY`,
`NTFY_CLICK`, `NTFY_AGENT_NAME` and `NTFY_EVENT` set. This is how you reach the
~100 services [Apprise](https://github.com/caronc/apprise) supports:

```sh
NTFY_AGENT_URLS='cmd://apprise -t "$NTFY_TITLE" -b "$NTFY_BODY" mailto://...'
```

A `cmd://` value cannot contain a bare comma; that separates destinations.

</details>

## Settings

A notification you learn to ignore is worse than none, so short turns, bursts
and overnight pings are filtered by default. Permission prompts always get
through; `snooze` is the only control that silences them.

| Setting | Default | What it does |
|---|---|---|
| `NTFY_AGENT_URLS` | none | Destinations, comma separated |
| `NTFY_AGENT_EVENTS` | `done,needs_input` | Set to `needs_input` for the biggest noise cut |
| `NTFY_AGENT_MIN_SECONDS` | `60` | Skip finished turns shorter than this |
| `NTFY_AGENT_DEBOUNCE_SECONDS` | `30` | One ping per window, per session |
| `NTFY_AGENT_QUIET_HOURS` | none | e.g. `23:00-07:00`, local time. Mutes finished turns only |
| `NTFY_AGENT_BODY` | `summary` | `none` sends the title only |
| `NTFY_AGENT_MAX_BODY` | `300` | Truncate the message to this many characters |
| `NTFY_AGENT_CLICK` | none | Tap-through URL; `{cwd}` `{session}` `{agent}` |
| `NTFY_AGENT_DESKTOP` | `auto` | Banner: `auto`, `always`, `never` |
| `NTFY_AGENT_TIMEOUT` | `5` | Per-request ceiling, in seconds |

```sh
NTFY_AGENT_CLICK="vscode://file{cwd}"     # tap to reopen the project
NTFY_AGENT_EVENTS=needs_input             # only when you are blocked
```

Precedence: **environment** > **plugin options** > **config file** > **defaults**.
As a plugin, `urls`, `desktop`, `min_seconds`, `quiet_hours` and `body` are
prompted for at enable time. `ntfy-agent status` shows what took effect.

The config file is read as shell, so wrap a value containing `$` or a backtick
in single quotes.

## Commands

| Command | What it does |
|---|---|
| `ntfy-agent setup` | Ask three questions, write the config, offer to wire up |
| `ntfy-agent install [agent...]` | Wire hooks into detected agents |
| `ntfy-agent test` | Send a test notification |
| `ntfy-agent status` | Show config and which agents are wired |
| `ntfy-agent doctor` | Diagnose problems, with a fix for each |
| `ntfy-agent snooze [minutes\|off]` | Mute for a while, 60 minutes by default |
| `ntfy-agent send <title> [body]` | Send an ad-hoc notification |
| `ntfy-agent uninstall` | Remove hooks, keep config |
| `ntfy-agent --version` | Print the version |

`send` is useful on its own:

```sh
make deploy && ntfy-agent send "deploy done" || ntfy-agent send "deploy FAILED"
```

## Troubleshooting

`ntfy-agent doctor` prints a fix for every failure it finds. Otherwise:

| Symptom | Cause and fix |
|---|---|
| Nothing arrives | The agent session predates the install. Restart it, then check `status` shows `hooks=yes`. |
| Only some turns notify | Working as designed. Turns under `NTFY_AGENT_MIN_SECONDS` are skipped; set it to `0` to see everything. |
| Too many notifications | Raise `NTFY_AGENT_DEBOUNCE_SECONDS`, or set `NTFY_AGENT_EVENTS=needs_input`. |
| Two notifications per turn | Both the plugin and `ntfy-agent install` are wired. Keep one. |
| No desktop banner on Windows | `Install-Module BurntToast -Scope CurrentUser`. The phone push still goes out. |

## Security

> [!IMPORTANT]
> **On ntfy.sh the topic is the password.** There is no login, and messages are
> cached server-side, so anyone who learns your topic can read everything you
> have sent. `setup` generates a random 128-bit topic and writes the config `600`.

`NTFY_AGENT_BODY=summary`, the default, sends the agent's last message, which can
contain code and file paths. `NTFY_AGENT_BODY=none` sends only the title.

[SECURITY.md](SECURITY.md) has the threat model and how to report a vulnerability.

## Uninstall

```sh
ntfy-agent uninstall                       # hooks only, config kept
curl -fsSL .../install.sh | sh -s -- --uninstall   # everything
```

As a plugin: `/plugin uninstall ntfy-agent@ntfy-agent`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Changes and versions are in
[CHANGELOG.md](CHANGELOG.md).

MIT licensed.
