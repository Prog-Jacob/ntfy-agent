#!/bin/sh
# Self-contained test suite. No framework: the assertions are the point.
# Every send goes to a fake HTTP sink, so running this never contacts a network.
#
# Usage: sh test/test.sh   (exit 0 = all passed)

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/bin/ntfy-agent"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0 FAIL=0
HAVE_JQ=no; command -v jq >/dev/null 2>&1 && HAVE_JQ=yes

# Isolate every run from the real machine.
export XDG_CONFIG_HOME="$TMP/config"
export XDG_STATE_HOME="$TMP/state"
export HOME="$TMP/home"
mkdir -p "$HOME"
STATE="$XDG_STATE_HOME/ntfy-agent"
CONF_DIR="$XDG_CONFIG_HOME/ntfy-agent"
conf="$CONF_DIR/config"
# cmd:// writes what it was given to a file, which makes delivery observable
# without a server and without leaving the machine.
SINK="$TMP/sink"
export NTFY_AGENT_URLS="cmd://printf '%s\\n%s\\n' \"\$NTFY_TITLE\" \"\$NTFY_BODY\" >>\"$SINK\""
export NTFY_AGENT_DESKTOP=never
export NTFY_AGENT_MIN_SECONDS=0
export NTFY_AGENT_DEBOUNCE_SECONDS=0

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi
}
# assert <label> <cmd...>, and refute for the inverse. Pass `test` for a
# condition. Replaces `cmd && ok L || bad L`, which had to repeat the label and,
# per SC2015, ran bad when ok itself failed. Reach for contains when the
# subject is a pipeline's output rather than its status.
assert() { a_l=$1; shift; if "$@"; then ok "$a_l"; else bad "$a_l"; fi; }
refute() { a_l=$1; shift; if "$@"; then bad "$a_l"; else ok "$a_l"; fi; }
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
contains() { # contains <label> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$2] not found in [$3]" ;; esac
}
missing() { # missing <label> <needle> <haystack>
  case "$3" in *"$2"*) bad "$1" "[$2] should not appear in [$3]" ;; *) ok "$1" ;; esac
}
jqok() { # jqok <label> <filter> <file>: skipped outright when jq is absent
  [ "$HAVE_JQ" = yes ] || return 0
  if jq -e "$2" "$3" >/dev/null 2>&1; then ok "$1"
  else bad "$1" "$(cat "$3" 2>/dev/null)"; fi
}

# Run a hook against a freshly emptied sink. Environment assignments for the
# hook process follow the payload, so a gate can be varied without a var prefix,
# which dash leaks into the calling shell.
hookrun() { # hookrun <agent> <role> <payload> [VAR=value...]
  hr_a=$1; hr_r=$2; hr_p=$3; shift 3
  : >"$SINK"
  printf '%s' "$hr_p" | env "$@" "$BIN" hook "$hr_a" "$hr_r"
}
fire() { # fire <agent> <role> <payload> [VAR=value...] -> what reached the sink
  hookrun "$@"
  # The sender is deliberately detached, so poll rather than assume it is done.
  await "$SINK"
  cat "$SINK" 2>/dev/null
}
silent() { # silent <label> <agent> <role> <payload> [VAR=value...]
  s_label=$1; shift
  hookrun "$@"
  sleep 1
  check "$s_label" "" "$(cat "$SINK")"
}
# Wait for a file to appear rather than guessing at a sleep.
await() {
  i=0
  while [ "$i" -lt 60 ] && [ ! -s "$1" ]; do sleep 0.1; i=$((i + 1)); done
}

# The whole hook contract over one input: prints nothing, exits 0.
silent_ok() { # silent_ok <label> <payload> [agent] [role]
  so_a=${3:-claude}; so_r=${4:-stop}
  so_out=$(printf '%s' "$2" | "$BIN" hook "$so_a" "$so_r" 2>&1)
  check "$1 prints nothing" "" "$so_out"
  printf '%s' "$2" | "$BIN" hook "$so_a" "$so_r" >/dev/null 2>&1
  check "$1 still exits 0" 0 $?
  reset_state
}

# nothing_sent <label> <role> <payload> [VAR=value...]
#
# A bare "the sink stayed empty" assertion passes just as happily when sending
# is broken outright, so every suppression test first proves the pipeline is
# live with a canary event, then proves this particular one is suppressed.
#
# Set PREP to a command that runs after the state reset when a test needs to
# arrange something the gate depends on, such as a turn-start stamp.
nothing_sent() {
  label=$1; role=$2; payload=$3; shift 3
  reset_state
  if [ -z "$(fire claude stop '{"session_id":"canary","cwd":"/tmp/p"}')" ]; then
    bad "$label" "the canary never landed, so the sink is dead, not the gate"
    reset_state; PREP=
    return
  fi
  reset_state
  [ -n "${PREP:-}" ] && eval "$PREP"
  PREP=
  # The canary just showed how long a delivery takes, so silent's short settle
  # is enough to catch one that was not suppressed.
  silent "$label" claude "$role" "$payload" "$@"
  reset_state
}

# Nothing in the suite needs state to survive between tests.
reset_state() { rm -rf "$STATE"; }

say() { printf '\n%s\n' "$1"; }

# --------------------------------------------------------------------------
say "contract: a hook must be silent and must exit 0"
# This is the whole safety story. On Gemini any code other than 0 or 1 becomes
# decision:"deny", and exit 2 blocks the turn on Claude, Codex and Cursor.
for spec in 'a well formed payload|{"session_id":"s1"}' \
            'a garbage payload|not json at all {{{' \
            'an empty payload|'; do
  silent_ok "${spec%%|*}" "${spec#*|}"
done
silent_ok "an unknown agent and role" '' bogus-agent bogus-role

# A closed fd 0 is not a tty either, and reading it used to deadlock the hook
# against its own capture pipe under bash and macOS sh.
start=$(date +%s)
"$BIN" hook claude stop 0<&- >/dev/null 2>&1
rc=$?
took=$(( $(date +%s) - start ))
check "a closed stdin exits 0" 0 "$rc"
assert "a closed stdin does not hang" test "$took" -lt 5
reset_state

# A hung transport must not stall the agent, even when the agent captures the
# hook's output. A command substitution blocks until every writer to the pipe
# closes it, so a detached child that inherited stdout hangs the parent long
# after the hook itself has exited.
start=$(date +%s)
out=$(printf '%s' '{"session_id":"hang","cwd":"/tmp/p"}' \
  | NTFY_AGENT_URLS="cmd://sleep 20" "$BIN" hook claude stop)
took=$(( $(date +%s) - start ))
assert "a hung transport does not block a capturing caller" test "$took" -lt 5
reset_state

# --------------------------------------------------------------------------
say "per-agent payload extraction"
r=$(fire claude stop '{"session_id":"a","cwd":"/tmp/proj","last_assistant_message":"claude said this"}')
contains "claude: last_assistant_message becomes the body" "claude said this" "$r"
contains "claude: title names the agent" "Claude Code finished" "$r"
contains "claude: title names the project" "proj" "$r"
# A branch is a useful suffix; git's "HEAD" for a detached or unborn one is not.
mkdir -p "$TMP/repo" && git -C "$TMP/repo" init -q 2>/dev/null
r=$(fire claude stop "{\"session_id\":\"br\",\"cwd\":\"$TMP/repo\"}")
missing "no @HEAD suffix before the first commit" "@HEAD" "$r"
reset_state
reset_state

r=$(fire gemini stop '{"session_id":"b","cwd":"/tmp/proj","prompt_response":"gemini said this"}')
contains "gemini: reads prompt_response, not last_assistant_message" "gemini said this" "$r"
reset_state

r=$(fire cursor stop '{"conversation_id":"c","cwd":"/tmp/proj","status":"completed"}')
contains "cursor: conversation_id is accepted in place of session_id" "Cursor finished" "$r"
reset_state

# Cursor's stop carries no text, so afterAgentResponse has to be stashed first.
printf '%s' '{"conversation_id":"c2","cwd":"/tmp/proj","text":"cursor text here"}' \
  | "$BIN" hook cursor response
r=$(fire cursor stop '{"conversation_id":"c2","cwd":"/tmp/proj","status":"completed"}')
contains "cursor: stashed response text is used on stop" "cursor text here" "$r"
reset_state

r=$(fire cursor stop '{"conversation_id":"c3","status":"aborted"}')
check "cursor: an aborted turn sends nothing" "" "$r"
reset_state

# An abort must consume the stash too, or its text goes out with the next turn.
printf '%s' '{"conversation_id":"c4","cwd":"/tmp/proj","text":"FROM THE ABORTED TURN"}' \
  | "$BIN" hook cursor response
printf '%s' '{"conversation_id":"c4","cwd":"/tmp/proj","status":"aborted"}' \
  | "$BIN" hook cursor stop
r=$(fire cursor stop '{"conversation_id":"c4","cwd":"/tmp/proj","status":"completed"}')
missing "cursor: an aborted turn's text never reaches a later one" \
  "FROM THE ABORTED TURN" "$r"
reset_state

# Codex's legacy notify passes JSON as argv, and gives the process no stdin.
: >"$SINK"
"$BIN" hook codex notify '{"type":"agent-turn-complete","thread-id":"t1","cwd":"/tmp/proj","last-assistant-message":"codex said this"}'
await "$SINK"
contains "codex: payload read from argv, hyphenated keys" "codex said this" "$(cat "$SINK")"
reset_state

: >"$SINK"
"$BIN" hook codex notify '{"type":"some-other-event","thread-id":"t2"}'
sleep 1
check "codex: a non-turn-complete event sends nothing" "" "$(cat "$SINK")"
reset_state

# --------------------------------------------------------------------------
say "notification typing: branch on the type, never on the message text"
r=$(fire claude notification '{"session_id":"n1","cwd":"/tmp/proj","notification_type":"permission_prompt","message":"Allow Bash?"}')
contains "permission_prompt is treated as needs input" "needs input" "$r"
contains "permission_prompt keeps the message" "Allow Bash?" "$r"
reset_state

r=$(fire gemini notification '{"session_id":"n2","cwd":"/tmp/proj","notification_type":"ToolPermission","message":"Allow?"}')
contains "gemini ToolPermission is treated as needs input" "needs input" "$r"
reset_state

nothing_sent "an unrelated notification type sends nothing" notification \
  '{"session_id":"n3","cwd":"/tmp/proj","notification_type":"auth_success"}' \
  NTFY_AGENT_DESKTOP=never

# --------------------------------------------------------------------------
say "gates"
nothing_sent "an event not in NTFY_AGENT_EVENTS is dropped" stop \
  '{"session_id":"g1","cwd":"/tmp/p"}' NTFY_AGENT_EVENTS=needs_input

# shellcheck disable=SC2016  # deliberately unexpanded: nothing_sent evals this
PREP='printf "%s" "{\"session_id\":\"g2\",\"cwd\":\"/tmp/p\"}" | "$BIN" hook claude start'
nothing_sent "a turn shorter than MIN_SECONDS is dropped" stop \
  '{"session_id":"g2","cwd":"/tmp/p"}' NTFY_AGENT_MIN_SECONDS=600

# ...but a blocked agent is always worth a ping, however fast it blocked.
printf '%s' '{"session_id":"g3","cwd":"/tmp/p"}' | "$BIN" hook claude start
r=$(fire claude notification \
  '{"session_id":"g3","cwd":"/tmp/p","notification_type":"permission_prompt","message":"Allow?"}' \
  NTFY_AGENT_MIN_SECONDS=600)
contains "MIN_SECONDS never suppresses needs_input" "needs input" "$r"
reset_state

# Backdate the turn-start stamp rather than waiting out a real duration.
stampdir="$STATE/started"
mkdir -p "$stampdir"
date +%s >"$stampdir/mb"
silent "a turn under MIN_SECONDS is dropped" claude stop \
  '{"session_id":"mb","cwd":"/tmp/p"}' \
  NTFY_AGENT_MIN_SECONDS=600 NTFY_AGENT_DEBOUNCE_SECONDS=3600
printf '%s' "$(( $(date +%s) - 700 ))" >"$stampdir/mb"
r=$(fire claude stop '{"session_id":"mb","cwd":"/tmp/p"}' \
  NTFY_AGENT_MIN_SECONDS=600 NTFY_AGENT_DEBOUNCE_SECONDS=3600)
assert "a turn dropped for being short does not consume the debounce window" \
  test -n "$r"
reset_state

# needs_input must not be swallowed by a long debounce window: approving one
# prompt and then never hearing about the next is the failure this tool exists
# to prevent.
fire claude notification \
  '{"session_id":"ni","cwd":"/tmp/p","notification_type":"permission_prompt","message":"first"}' \
  NTFY_AGENT_DEBOUNCE_SECONDS=3600 >/dev/null
# Backdate the debounce stamp rather than sleeping past the 5 second cap, so
# this is deterministic instead of a race with a boundary.
printf '%s' "$(( $(date +%s) - 60 ))" >"$STATE/debounce/ni-needs_input"
r=$(fire claude notification \
  '{"session_id":"ni","cwd":"/tmp/p","notification_type":"permission_prompt","message":"second"}' \
  NTFY_AGENT_DEBOUNCE_SECONDS=3600)
contains "a later permission prompt is not swallowed by a long window" "second" "$r"
reset_state

# Debounce collapses a burst, and is keyed per session so parallel projects
# cannot silence each other.
r=$(fire claude stop '{"session_id":"d1","cwd":"/tmp/p"}' NTFY_AGENT_DEBOUNCE_SECONDS=300)
assert "first ping in the window is sent" test -n "$r"
silent "a repeat within the window is dropped" claude stop \
  '{"session_id":"d1","cwd":"/tmp/p"}' NTFY_AGENT_DEBOUNCE_SECONDS=300
r=$(fire claude stop '{"session_id":"OTHER","cwd":"/tmp/p"}' NTFY_AGENT_DEBOUNCE_SECONDS=300)
assert "a different session is not debounced" test -n "$r"
# The window is claimed with a lock directory, released on every exit path. One
# left behind mutes that session for good, and both paths just ran for d1: the
# hook that sent, and the hook that was debounced.
refute "no debounce lock outlives the hook that took it" \
  test -d "$STATE/debounce/d1-done.lock"
reset_state

# A hook killed outright never runs its trap, so it leaves the lock behind. The
# two assertions are a pair: a lock a live hook still holds must suppress, and
# one older than any agent's hook timeout must be reclaimed instead of muting
# the session permanently. The second also proves the sink was alive throughout.
mkdir -p "$STATE/debounce/lk-done.lock"
silent "a lock a live hook still holds suppresses" claude stop \
  '{"session_id":"lk","cwd":"/tmp/p"}'
touch -t "$(date -v-5M +%Y%m%d%H%M 2>/dev/null || date -d '5 minutes ago' +%Y%m%d%H%M)" \
  "$STATE/debounce/lk-done.lock"
r=$(fire claude stop '{"session_id":"lk","cwd":"/tmp/p"}')
assert "a lock left by a killed hook is reclaimed" test -n "$r"
reset_state

"$BIN" snooze 60 >/dev/null
silent "snooze suppresses everything" claude stop '{"session_id":"s9","cwd":"/tmp/p"}'
"$BIN" snooze off >/dev/null
reset_state

# Quiet hours mute finished turns only: a blocked agent would otherwise sit
# idle until morning.
now=$(date +%H%M); nh=$(printf '%s' "$now" | cut -c1-2)
silent "quiet hours mute a finished turn" claude stop '{"session_id":"q1","cwd":"/tmp/p"}' \
  NTFY_AGENT_QUIET_HOURS="$nh:00-$nh:59"
reset_state
r=$(fire claude notification \
  '{"session_id":"q2","cwd":"/tmp/p","notification_type":"permission_prompt","message":"Allow?"}' \
  NTFY_AGENT_QUIET_HOURS="$nh:00-$nh:59")
contains "quiet hours still let needs_input through" "needs input" "$r"
reset_state

# status reports desktop_ok without putting a banner on screen. Whether a
# machine has a backend is not assertable, so it is not asserted.
out=$(NTFY_AGENT_DESKTOP=never "$BIN" status | grep '^desktop')
contains "never reports the banner unavailable" "unavailable here" "$out"
out=$(env -u CI NTFY_AGENT_DESKTOP=auto SSH_CONNECTION="10.0.0.1 22 10.0.0.2 22" \
  "$BIN" status | grep '^desktop')
contains "auto skips the banner over SSH" "unavailable here" "$out"

# With nowhere to send and no banner, the hook gives up before claiming a
# debounce window. The second run proves the directory is what marks that.
reset_state
printf '%s' '{"session_id":"dk","cwd":"/tmp/p"}' \
  | env NTFY_AGENT_URLS= NTFY_AGENT_DESKTOP=never "$BIN" hook claude stop
sleep 0.5
refute "no destination and no banner claims no debounce window" \
  test -d "$STATE/debounce"
fire claude stop '{"session_id":"dk2","cwd":"/tmp/p"}' >/dev/null
assert "a run with a destination does claim one" test -d "$STATE/debounce"
reset_state

# --------------------------------------------------------------------------
say "body handling"
long=$(printf 'x%.0s' $(seq 1 900))
r=$(fire claude stop \
  "{\"session_id\":\"b1\",\"cwd\":\"/tmp/p\",\"last_assistant_message\":\"$long\"}" \
  NTFY_AGENT_MAX_BODY=50)
body=$(printf '%s' "$r" | sed -n 2p)
check "body is truncated to MAX_BODY" 50 "${#body}"
reset_state

r=$(fire claude stop \
  '{"session_id":"b2","cwd":"/tmp/p","last_assistant_message":"secret code here"}' \
  NTFY_AGENT_BODY=none)
missing "BODY=none keeps the message off the wire" "secret code here" "$r"
reset_state

# A header value cannot contain a newline, and agent messages routinely do.
r=$(fire claude stop \
  '{"session_id":"b3","cwd":"/tmp/p","last_assistant_message":"line one\nline two\ttabbed"}')
body=$(printf '%s' "$r" | sed -n 2p)
contains "newlines in the message are flattened" "line one line two" "$body"
check "the sent body is a single line" 2 "$(printf '%s\n' "$r" | wc -l | tr -d ' ')"
reset_state

r=$(fire claude stop '{"session_id":"b4","cwd":"/tmp/p"}')
contains "a missing message falls back to a usable body" "Turn complete" "$r"
reset_state

# Shell metacharacters in agent output must not reach a shell.
r=$(fire claude stop \
  "{\"session_id\":\"b5\",\"cwd\":\"/tmp/p\",\"last_assistant_message\":\"rm -rf \$(touch $TMP/pwned) \`id\` quoted\"}")
refute "agent text is not executed" test -e "$TMP/pwned"
reset_state

# --------------------------------------------------------------------------
say "elapsed time"
printf '%s' '{"session_id":"e1","cwd":"/tmp/p"}' | "$BIN" hook claude start
# Backdate the stamp so a duration is measurable without waiting for one. The
# file is named for the session id, which state_path leaves alone here.
printf '%s' "$(( $(date +%s) - 125 ))" >"$STATE/started/e1"
r=$(fire claude stop '{"session_id":"e1","cwd":"/tmp/p"}')
contains "elapsed minutes appear in the title" "(2m)" "$r"
reset_state

# --------------------------------------------------------------------------
say "config precedence: environment beats the file"
mkdir -p "$CONF_DIR"
cat >"$conf" <<EOF
NTFY_AGENT_URLS="cmd://printf 'FROM_FILE\\n' >>\"$SINK\""
NTFY_AGENT_MAX_BODY=11
NTFY_AGENT_DESKTOP=never
EOF
r=$(fire claude stop '{"session_id":"p1","cwd":"/tmp/p","last_assistant_message":"hello"}')
missing "the exported env URL wins over the file" "FROM_FILE" "$r"
: >"$SINK"
# With no env override present, the file's value must take effect.
r=$(env -u NTFY_AGENT_URLS sh -c "printf '%s' '{\"session_id\":\"p2\",\"cwd\":\"/tmp/p\"}' | \
  \"$BIN\" hook claude stop; sleep 0.5; cat \"$SINK\"")
contains "the file is used when the env is unset" "FROM_FILE" "$r"
rm -f "$conf"
reset_state

printf 'NTFY_AGENT_QUIET_HOURS="00:00-23:59"\n' >"$conf"
out=$(NTFY_AGENT_QUIET_HOURS="" "$BIN" status | grep gates)
missing "an empty env var overrides a config value" "00:00-23:59" "$out"
rm -f "$conf"

# --------------------------------------------------------------------------
say "Claude Code plugin options"
# The plugin exports CLAUDE_PLUGIN_OPTION_<KEY>; ${user_config.*} is rejected in
# shell-form hook commands, so the environment is the only supported route.
PLUGIN_URLS="cmd://printf 'VIA_PLUGIN\n' >>\"$SINK\""
r=$(env -u NTFY_AGENT_URLS CLAUDE_PLUGIN_OPTION_URLS="$PLUGIN_URLS" \
  sh -c "printf '%s' '{\"session_id\":\"pl1\",\"cwd\":\"/tmp/p\"}' | \
    \"$BIN\" hook claude stop; sleep 0.5; cat \"$SINK\"")
contains "a plugin option supplies the destination" "VIA_PLUGIN" "$r"
: >"$SINK"
reset_state

# A real environment variable must still outrank a plugin option.
r=$(fire claude stop '{"session_id":"pl2","cwd":"/tmp/p"}' \
  CLAUDE_PLUGIN_OPTION_URLS="$PLUGIN_URLS")
missing "an explicit env var outranks a plugin option" "VIA_PLUGIN" "$r"
reset_state

# env -u matters: the suite exports MIN_SECONDS=0, which correctly outranks a
# plugin option, so it has to be out of the way to observe the option at all.
r=$(env -u NTFY_AGENT_MIN_SECONDS CLAUDE_PLUGIN_OPTION_MIN_SECONDS=99999 sh -c "\
  printf '%s' '{\"session_id\":\"pl3\",\"cwd\":\"/tmp/p\"}' | \"$BIN\" hook claude start; \
  : >\"$SINK\"; \
  printf '%s' '{\"session_id\":\"pl3\",\"cwd\":\"/tmp/p\"}' | \"$BIN\" hook claude stop; \
  sleep 0.5; cat \"$SINK\"")
check "a plugin option gates as well as a config value does" "" "$r"
reset_state

# State lives in one place however the hook was wired. Keying it on
# CLAUDE_PLUGIN_DATA, which only the plugin's hook sees, hid snoozes from that
# hook and gave a doubly-wired machine two debounce windows.
pd="$TMP/plugindata"
CLAUDE_PLUGIN_DATA="$pd" sh -c "printf '%s' '{\"session_id\":\"pd1\",\"cwd\":\"/tmp/p\"}' \
  | \"$BIN\" hook claude start"
assert "the plugin's hook writes state where the CLI reads it" \
  test -d "$STATE/started"
refute "no second state directory appears under CLAUDE_PLUGIN_DATA" test -d "$pd"
reset_state

# A snooze set from a terminal must silence the plugin's hook.
"$BIN" snooze 60 >/dev/null
silent "snooze set from the CLI silences the plugin's hook" claude stop \
  '{"session_id":"sn1","cwd":"/tmp/p"}' CLAUDE_PLUGIN_DATA="$TMP/plugindata2"
"$BIN" snooze off >/dev/null
reset_state

# --------------------------------------------------------------------------
say "the other agents and subcommands"
# generic is the documented extension point for anything that can run a command.
r=$(fire generic 'done' '{"session_id":"gen","cwd":"/tmp/proj","last_assistant_message":"from generic"}')
contains "the generic agent reports a finished turn" "from generic" "$r"
reset_state
r=$(fire generic needs_input '{"session_id":"gen2","cwd":"/tmp/proj","message":"blocked"}')
contains "the generic agent reports needing input" "needs input" "$r"
reset_state
r=$(fire copilot stop '{"session_id":"cp","cwd":"/tmp/proj","last_assistant_message":"copilot said"}')
contains "copilot reports a finished turn" "copilot said" "$r"
reset_state

# Copilot's agentStop carries no assistant text and spells the session
# sessionId, so both have to come from somewhere else.
r=$(fire copilot stop '{"sessionId":"cp2","cwd":"/tmp/proj","stopReason":"completed"}')
contains "copilot: a turn with no text still reports" "Copilot finished" "$r"
reset_state
r=$(fire copilot notification \
  '{"sessionId":"cp3","cwd":"/tmp/proj","notification_type":"agent_completed","message":"copilot text here"}')
contains "copilot: the finished-turn text comes from the notification hook" \
  "copilot text here" "$r"
reset_state
r=$(fire copilot notification \
  '{"sessionId":"cp4","cwd":"/tmp/proj","notification_type":"agent_idle","message":"waiting"}')
contains "copilot: agent_idle is treated as needs input" "needs input" "$r"
reset_state
fire copilot stop '{"sessionId":"cpA","cwd":"/tmp/proj"}' NTFY_AGENT_DEBOUNCE_SECONDS=300 >/dev/null
r=$(fire copilot stop '{"sessionId":"cpB","cwd":"/tmp/proj"}' NTFY_AGENT_DEBOUNCE_SECONDS=300)
assert "copilot: sessionId keys the debounce" test -n "$r"
reset_state

# Quiet hours wrapping past midnight is a separate branch from the simple case.
# Strip the leading zero rather than using $((10#..)), which is a bashism dash
# rejects, and is the same trap the program itself had to avoid.
hh=$(date +%H | sed 's/^0//'); hh=${hh:-0}
prev=$(( (hh + 23) % 24 )); next=$(( (hh + 1) % 24 ))
wrap=$(printf '%02d:00-%02d:00' "$prev" "$next")
silent "a window that wraps past midnight still mutes" claude stop \
  '{"session_id":"qw","cwd":"/tmp/p"}' NTFY_AGENT_QUIET_HOURS="$wrap"
reset_state
# ...and a window that excludes now must not mute.
away=$(printf '%02d:00-%02d:00' "$next" "$prev")
r=$(fire claude stop '{"session_id":"qa","cwd":"/tmp/p"}' NTFY_AGENT_QUIET_HOURS="$away")
assert "a wrapping window that excludes now does not mute" test -n "$r"
reset_state

# send is documented as useful on its own.
: >"$SINK"
"$BIN" send "deploy done" "all green" >/dev/null 2>&1
contains "send delivers an ad-hoc notification" "deploy done" "$(cat "$SINK")"
"$BIN" send >/dev/null 2>&1
check "send with no arguments exits non-zero" 1 $?

# A command that failed must say so and exit non-zero, or the user believes a
# broken setup is working.
: >"$SINK"
NTFY_AGENT_URLS="cmd://exit 1" "$BIN" test >/dev/null 2>&1
check "test exits non-zero when a destination fails" 1 $?
out=$(NTFY_AGENT_URLS="cmd://exit 1" "$BIN" test 2>&1)
contains "test names the failure instead of claiming success" "failed" "$out"
NTFY_AGENT_URLS="cmd://true" "$BIN" test >/dev/null 2>&1
check "test exits 0 when every destination succeeds" 0 $?

if [ "$HAVE_JQ" = yes ]; then
  mkdir -p "$HOME/.claude"
  printf 'not json at all' >"$HOME/.claude/settings.json"
  "$BIN" install claude >/dev/null 2>&1
  check "install exits non-zero when it cannot edit a config" 1 $?
  check "the uneditable file is left untouched" "not json at all" \
    "$(cat "$HOME/.claude/settings.json")"
  rm -f "$HOME/.claude/settings.json"
fi

# A hand-edited config must not be able to disable a gate by being unreadable.
out=$(NTFY_AGENT_MIN_SECONDS=abc "$BIN" status | grep gates)
contains "a non-numeric setting falls back to its default" "min 60s" "$out"

say "setup, status, doctor"
out=$("$BIN" setup 2>&1)
contains "setup writes a config" "Wrote" "$out"
contains "setup tells the user the topic is a password" "password" "$out"
mode=$(stat -c '%a' "$conf" 2>/dev/null || stat -f '%Lp' "$conf" 2>/dev/null)
check "the config is created mode 600, never chmod-ed after" 600 "$mode"
t1=$(sed -n 's/^NTFY_AGENT_URLS="ntfy:\/\/\(.*\)"$/\1/p' "$conf")
assert "the generated topic is long enough to be unguessable" test "${#t1}" -ge 20
rm -f "$conf"
out=$("$BIN" setup 2>&1)
t2=$(sed -n 's/^NTFY_AGENT_URLS="ntfy:\/\/\(.*\)"$/\1/p' "$conf")
assert "each setup generates a fresh random topic" test "$t1" != "$t2"
# A prompt must never reach a script, a pipe or CI.
missing "setup asks nothing when nobody is watching" "[60]" "$out"
missing "setup wires no hooks when nobody is watching" "Wiring" "$out"

out=$("$BIN" status 2>&1)
missing "status never prints the topic" "$t2" "$out"
contains "status redacts the destination" "redacted" "$out"

"$BIN" doctor >/dev/null 2>&1
rc=$?
assert "doctor exits 0 or 1, never crashes" test "$rc" -le 1
out=$("$BIN" doctor 2>&1)
missing "doctor never prints the topic" "$t2" "$out"
rm -f "$conf"

out=$(NTFY_AGENT_URLS='cmd://notify-send hi there' "$BIN" doctor 2>&1)
missing "doctor does not split a destination on spaces" "unknown destination scheme" "$out"
out=$(NTFY_AGENT_URLS='bogus://x' "$BIN" doctor 2>&1)
contains "doctor still reports a genuinely unknown scheme" \
  'unknown destination scheme "bogus"' "$out"

out=$("$BIN" --version 2>&1)
contains "--version reports a version" "ntfy-agent" "$out"
out=$("$BIN" 2>&1)
contains "bare invocation shows usage" "notify your phone" "$out"
"$BIN" nonsense-command >/dev/null 2>&1
check "an unknown command exits non-zero" 1 $?

# --------------------------------------------------------------------------
say "install and uninstall are idempotent and leave no trace"
if [ "$HAVE_JQ" = yes ]; then
  CS="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  printf '%s' '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo pre-existing"}]}]}}' \
    >"$CS"

  "$BIN" install claude >/dev/null 2>&1
  jqok "install appends without dropping an existing hook" '.hooks.Stop | length == 2' "$CS"
  jqok "install leaves unrelated settings alone" '.model == "opus"' "$CS"
  jqok "install wires all three Claude events" \
    '.hooks.Notification and .hooks.UserPromptSubmit' "$CS"

  "$BIN" install claude >/dev/null 2>&1
  n=$(jq '[.. | objects | select(.command? // "" | test("ntfy-agent"))] | length' "$CS")
  check "installing twice does not duplicate the hook" 3 "$n"

  "$BIN" uninstall >/dev/null 2>&1
  n=$(jq '[.. | objects | select(.command? // "" | test("ntfy-agent"))] | length' "$CS")
  check "uninstall removes every hook of ours" 0 "$n"
  jqok "uninstall keeps the pre-existing hook" '.hooks.Stop | length == 1' "$CS"
  jqok "uninstall leaves unrelated settings alone" '.model == "opus"' "$CS"

  # Codex: notify is a top-level TOML key, so it must land above any [table].
  mkdir -p "$HOME/.codex"
  printf '[tui]\nnotifications = true\n' >"$HOME/.codex/config.toml"
  "$BIN" install codex >/dev/null 2>&1
  contains "codex: notify is prepended above the first table" "notify = " \
    "$(head -1 "$HOME/.codex/config.toml")"
  assert "codex: the existing table survives" grep -q '^\[tui\]' "$HOME/.codex/config.toml"
  contains "codex: a second install is a no-op" "already wired" \
    "$("$BIN" install codex 2>&1)"
  "$BIN" uninstall >/dev/null 2>&1
  refute "codex: uninstall is clean" grep -q 'ntfy-agent' "$HOME/.codex/config.toml"

  # An existing notify key belongs to someone else. Never overwrite it.
  printf 'notify = ["/usr/bin/other-tool"]\n' >"$HOME/.codex/config.toml"
  contains "codex: refuses to overwrite a foreign notify key" "SKIPPED" \
    "$("$BIN" install codex 2>&1)"
  assert "codex: the foreign notify key is intact" \
    grep -q 'other-tool' "$HOME/.codex/config.toml"
else
  printf '  skip  install and uninstall tests (jq not installed)\n'
fi

# --------------------------------------------------------------------------
say "transports do not let agent text turn into something else"
# Capture curl's argv and stdin without touching the network.
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/curl" <<CURLEOF
#!/bin/sh
{ printf 'ARGV:'; for a in "\$@"; do printf ' [%s]' "\$a"; done; echo; } >>"$TMP/argv.log"
# Record the config file contents and the body, which is what actually ships.
i=0
for a in "\$@"; do
  i=\$((i+1))
  if [ "\$a" = --config ]; then
    eval "cfg=\\\${\$((i+1))}"
    cat "\$cfg" >>"$TMP/cfg.log" 2>/dev/null
  fi
done
cat >>"$TMP/body.log" 2>/dev/null
# curl's own exit code, so a 4xx under --fail can be simulated.
exit \${FAKE_CURL_RC:-0}
CURLEOF
chmod +x "$FAKEBIN/curl"

curlfire() { # curlfire <urls> <payload>
  : >"$TMP/argv.log"; : >"$TMP/cfg.log"; : >"$TMP/body.log"
  printf '%s' "$2" | PATH="$FAKEBIN:$PATH" NTFY_AGENT_URLS="$1" "$BIN" hook claude stop
  await "$TMP/argv.log"
  sleep 0.3
}

# curl treats a value beginning with @ as "read this file". The body is the
# assistant's message, so an unlucky or hostile one could exfiltrate a file.
curlfire "ntfy://topic" \
  '{"session_id":"at1","cwd":"/tmp/p","last_assistant_message":"@/etc/passwd"}'
missing "a leading @ in the message is never handed to curl as a value" \
  "[@/etc/passwd]" "$(cat "$TMP/argv.log")"
contains "the body travels on stdin as @-" "[@-]" "$(cat "$TMP/argv.log")"
contains "the body itself still reaches curl" "@/etc/passwd" "$(cat "$TMP/body.log")"
reset_state

# Secrets must not be visible in ps.
curlfire "ntfy://sekrettoken@example.com/topic" \
  '{"session_id":"at2","cwd":"/tmp/p"}'
missing "an auth token never appears in curl argv" "sekrettoken" "$(cat "$TMP/argv.log")"
contains "the auth token travels in the curl config file" "sekrettoken" "$(cat "$TMP/cfg.log")"
reset_state

# A CR in agent-controlled text must not be able to split a header.
curlfire "ntfy://topic" \
  '{"session_id":"at3","cwd":"/tmp/p","last_assistant_message":"ok\r\nX-Evil: 1"}'
missing "a CR in the message cannot inject a header" "X-Evil" "$(cat "$TMP/cfg.log")"
reset_state

# The webhook body is JSON built by hand; session_id is agent-controlled.
curlfire "https://example.invalid/hook" \
  '{"session_id":"a\",\"admin\":true,\"x\":\"b","cwd":"/tmp/p"}'
missing "session_id cannot inject JSON keys into the webhook body" \
  '"admin":true' "$(cat "$TMP/body.log")"
jqok "the webhook body is valid JSON despite hostile input" . "$TMP/body.log"
reset_state

# json_escape used sed's N, which quits without printing at EOF on BSD sed, so
# every Discord, Slack and webhook message from a Mac shipped empty.
curlfire "https://example.invalid/hook" \
  '{"session_id":"at5","cwd":"/tmp/proj","last_assistant_message":"single line body"}'
contains "a single-line body survives JSON escaping" "single line body" \
  "$(cat "$TMP/body.log")"
reset_state

# cwd reaches the webhook without passing through oneline, and json_escape read
# its input in awk paragraph mode, which deleted blank lines instead of encoding
# them.
curlfire "https://example.invalid/hook" \
  '{"session_id":"bl","cwd":"/tmp/a\n\nb"}'
contains "a blank line in cwd is encoded, not swallowed" '/tmp/a\n\nb' \
  "$(cat "$TMP/body.log")"
reset_state

# A control character is illegal raw inside a JSON string, so an unlucky
# session_id could produce a body no receiver could parse.
curlfire "https://example.invalid/hook" \
  "$(printf '{"session_id":"a\001b","cwd":"/tmp/p"}')"
jqok "a control character does not break the JSON body" . "$TMP/body.log"
reset_state

# Asserting only that a Click header exists passes with the template unexpanded.
click() { # click <label> <template> <payload> <expected>
  : >"$TMP/cfg.log"
  printf '%s' "$3" | PATH="$FAKEBIN:$PATH" NTFY_AGENT_URLS="ntfy://topic" \
    NTFY_AGENT_CLICK="$2" "$BIN" hook claude stop
  await "$TMP/cfg.log"
  sleep 0.3
  contains "$1" "$4" "$(cat "$TMP/cfg.log")"
  reset_state
}
click "click: {cwd} {session} and {agent} are all substituted" \
  "vscode://file{cwd}?s={session}&a={agent}" \
  '{"session_id":"s7","cwd":"/tmp/proj"}' \
  "Click: vscode://file/tmp/proj?s=s7&a=claude"
# This was sed once: a | in the path ended the expression, an & expanded to the
# whole match.
click "click: a path with sed metacharacters survives" \
  "x://{cwd}" '{"session_id":"s8","cwd":"/tmp/a|b&c"}' \
  "Click: x:///tmp/a|b&c"
# BSD awk exits non-zero on a literal newline in -v, dropping the header. The
# newline must be encoded or the payload is not JSON and nothing is exercised.
click "click: a newline in session_id does not drop the header" \
  "vscode://file{cwd}?s={session}" \
  '{"session_id":"a\nb","cwd":"/tmp/p"}' \
  "Click: vscode://file/tmp/p?s=a b"

# A late notification is worthless, so the per-request ceiling has to reach curl.
curlfire "ntfy://topic" '{"session_id":"to","cwd":"/tmp/p"}'
contains "the timeout ceiling reaches curl" "max-time = 5" "$(cat "$TMP/cfg.log")"
reset_state

# Truncation must count characters, not bytes, or it emits a half character.
r=$(fire claude stop \
  '{"session_id":"tc","cwd":"/tmp/p","last_assistant_message":"ααααααααα"}' \
  NTFY_AGENT_MAX_BODY=5)
body=$(printf '%s' "$r" | sed -n 2p)
check "truncation keeps whole characters" 10 "$(printf '%s' "$body" | wc -c | tr -d ' ')"
reset_state

# Credentials must never be visible in ps, for every transport that has one.
for dest in "pover://usr@SEKRET" "tgram://SEKRET/chat" "gotify://SEKRET@host"; do
  curlfire "$dest" '{"session_id":"sec","cwd":"/tmp/p"}'
  missing "no credential in argv for ${dest%%:*}" "SEKRET" "$(cat "$TMP/argv.log")"
  contains "the ${dest%%:*} credential is in the config file" "SEKRET" "$(cat "$TMP/cfg.log")"
  reset_state
done

# Discord, Slack and the webhook build JSON by hand with printf, so a missing
# comma or quote ships a body the receiver rejects and nothing surfaces.
for spec in "discord://123/abc|.embeds[0].title and .embeds[0].description|the Discord body carries a title and a description" \
            "slack://T0/B0/xxx|.text|the Slack body carries a text field"; do
  rest=${spec#*|}
  curlfire "${spec%%|*}" \
    '{"session_id":"js","cwd":"/tmp/proj","last_assistant_message":"a \"quoted\" body"}'
  jqok "${rest#*|}" "${rest%%|*}" "$TMP/body.log"
  reset_state
done

# Telegram is sent as parse_mode=HTML, so unescaped markup in the agent's
# message makes Telegram reject the whole request and the user hears nothing.
curlfire "tgram://token/chat" \
  '{"session_id":"tg","cwd":"/tmp/proj","last_assistant_message":"a <b> & c"}'
# The message is a form field, so it is in argv rather than the config file.
contains "Telegram escapes HTML in the message" "&lt;b&gt; &amp; c" "$(cat "$TMP/argv.log")"
reset_state

# Apprise writes gotify host-first. Reading only the @ form left token and host
# both holding the whole string, so the credential went out as a path segment.
for spec in "gotify://TOK@host.invalid|https://host.invalid/message|token@host" \
            "gotify://host.invalid/TOK|https://host.invalid/message|host/token" \
            "gotify://host.invalid/sub/path/TOK|https://host.invalid/sub/path/message|a subpath"; do
  rest=${spec#*|}
  curlfire "${spec%%|*}" '{"session_id":"gt","cwd":"/tmp/p"}'
  contains "gotify: ${rest#*|} reaches the right endpoint" "url = ${rest%%|*}" \
    "$(cat "$TMP/cfg.log")"
  reset_state
done
curlfire "gotify://host.invalid" '{"session_id":"gt2","cwd":"/tmp/p"}'
check "gotify: a destination with no token sends nothing" "" "$(cat "$TMP/cfg.log")"
reset_state

# The scheme decides the protocol, and the plain-HTTP variant is the only way
# to reach a self-hosted instance without TLS.
for spec in "ntfy+http://example.invalid/topic|url = http://example.invalid/topic|ntfy+http posts over plain HTTP" \
            "ntfy://topic|url = https://ntfy.sh/topic|ntfy defaults to https on ntfy.sh"; do
  rest=${spec#*|}
  curlfire "${spec%%|*}" '{"session_id":"np","cwd":"/tmp/p"}'
  contains "${rest#*|}" "${rest%%|*}" "$(cat "$TMP/cfg.log")"
  reset_state
done

out=$(PATH="$FAKEBIN:$PATH" FAKE_CURL_RC=22 NTFY_AGENT_URLS="ntfy://topic" "$BIN" test 2>&1)
check "test exits non-zero when the server rejects the request" 1 $?
contains "test counts the rejected destination as failed" "1 destination(s) failed" "$out"

# One failing transport must never suppress the others; the code says so and
# nothing checked it.
fire claude stop '{"session_id":"multi","cwd":"/tmp/p"}' \
  NTFY_AGENT_URLS="bogus://x,cmd://printf ONE >>\"$SINK\",cmd://printf TWO >>\"$SINK\"" \
  >/dev/null
sleep 0.5
r=$(cat "$SINK")
contains "a bad destination does not stop the next one" "ONE" "$r"
contains "a bad destination does not stop the last one" "TWO" "$r"
reset_state

say "the payload reader does not depend on jq"
# Without jq the fallback extractor runs. It used GNU-only sed alternation,
# which matched nothing on BSD sed, so every field came back empty on macOS.
NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for t in sh awk sed tr cat date printf grep mkdir rm cut basename git stat ls uname find; do
  p=$(command -v $t 2>/dev/null) && ln -sf "$p" "$NOJQ/$t" 2>/dev/null
done
r=$(fire claude stop \
  '{"session_id":"nj","cwd":"/tmp/proj","last_assistant_message":"read without jq"}' \
  PATH="$NOJQ")
contains "the message is extracted with no jq on PATH" "read without jq" "$r"
reset_state

# Three shapes the fallback used to read differently from jq, so the
# notification text depended on whether jq was installed.
nojq() { # nojq <label> <payload> <expected>
  contains "no jq: $1" "$3" "$(fire claude stop "$2" PATH="$NOJQ")"
  reset_state
}
nojq "a unicode escape is decoded" \
  '{"session_id":"n1","cwd":"/tmp/proj","last_assistant_message":"\u0041\u0042 end"}' \
  "AB end"
nojq "a nested key of the same name is ignored" \
  '{"session_id":"n2","cwd":"/tmp/proj","tool_input":{"last_assistant_message":"NESTED"},"last_assistant_message":"REAL"}' \
  "REAL"
nojq "a key name inside a value is not mistaken for a key" \
  '{"session_id":"n3","cwd":"/tmp/proj","first":"a \"last_assistant_message\": \"DECOY\" b","last_assistant_message":"REAL"}' \
  "REAL"

say "install and uninstall never damage what is not ours"
if [ "$HAVE_JQ" = yes ]; then
  mkdir -p "$HOME/.claude"
  # A foreign hook whose name merely contains our own, plus explicit nulls.
  cat >"$CS" <<'JSONEOF'
{"cleanupPeriodDays":null,
 "env":{"FOO":null,"BAR":"1"},
 "hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/usr/local/bin/my-ntfy-agent-lint"}]}]}}
JSONEOF
  foreign='.hooks.PreToolUse[0].hooks[0].command == "/usr/local/bin/my-ntfy-agent-lint"'
  "$BIN" install claude >/dev/null 2>&1
  jqok "a foreign hook whose name contains ours is left alone" "$foreign" "$CS"
  "$BIN" uninstall >/dev/null 2>&1
  jqok "uninstall leaves the foreign hook alone too" "$foreign" "$CS"

  # Each JSON agent has its own filter with its own key names, and only claude
  # was covered. A typo in any of them ships a wiring that never fires.
  for spec in "gemini:.gemini/settings.json:AfterAgent:Notification:BeforeAgent" \
              "cursor:.cursor/hooks.json:stop:afterAgentResponse:beforeSubmitPrompt" \
              "copilot:.copilot/settings.json:agentStop:notification:userPromptSubmitted"; do
    a=${spec%%:*}; rest=${spec#*:}
    rel=${rest%%:*}; events=${rest#*:}
    mkdir -p "$HOME/$(dirname "$rel")"
    printf '%s' '{"keepMe":true}' >"$HOME/$rel"
    "$BIN" install "$a" >/dev/null 2>&1
    ok_all=yes
    # Split through a command substitution, not IFS: zsh leaves an unquoted
    # parameter unsplit, which made this loop run once and every agent fail.
    for e in $(printf '%s' "$events" | tr ':' ' '); do
      jq -e --arg e "$e" '.hooks[$e] | length > 0' "$HOME/$rel" >/dev/null 2>&1 || ok_all=no
    done
    if [ "$ok_all" = yes ]; then ok "$a wires all three of its events"
    else bad "$a wires all three of its events" "$(cat "$HOME/$rel")"; fi
    jqok "$a install leaves unrelated keys alone" '.keepMe == true' "$HOME/$rel"
    "$BIN" uninstall >/dev/null 2>&1
    jqok "$a uninstall removes every hook of ours" \
      '[.. | objects | select((.command? // .bash? // "") | test("ntfy-agent:hook"))] | length == 0' \
      "$HOME/$rel"
    rm -f "$HOME/$rel"
  done

  # Codex: a comment mentioning us must not be mistaken for our wiring, and
  # uninstall must not delete unrelated lines.
  mkdir -p "$HOME/.codex"
  cat >"$HOME/.codex/config.toml" <<'TOMLEOF'
# I also use ntfy-agent from another project, do not touch
[mcp_servers.foo]
command = "run-ntfy-agent-bridge"
TOMLEOF
  "$BIN" install codex >/dev/null 2>&1
  assert "codex: a mention of us in a comment does not block wiring" \
    grep -q '^notify = ' "$HOME/.codex/config.toml"
  "$BIN" uninstall >/dev/null 2>&1
  assert "codex: uninstall keeps unrelated lines that mention us" \
    grep -q 'run-ntfy-agent-bridge' "$HOME/.codex/config.toml"
  refute "codex: uninstall removed only our own line" \
    grep -q '^notify = ' "$HOME/.codex/config.toml"

  # And the round trip should be byte for byte, blank lines included.
  printf '[tui]\nnotifications = true\n' >"$HOME/.codex/config.toml"
  before=$(cat "$HOME/.codex/config.toml")
  "$BIN" install codex >/dev/null 2>&1
  "$BIN" uninstall >/dev/null 2>&1
  check "codex: install then uninstall is byte identical" \
    "$before" "$(cat "$HOME/.codex/config.toml")"
  rm -f "$CS" "$HOME/.codex/config.toml"

  # The prune used to walk the whole document and delete every explicit null.
  nulls='.model == null and .other.keep == null and (.arr | length) == 2'
  printf '%s' '{"model":null,"other":{"keep":null},"arr":[null,1]}' >"$CS"
  "$BIN" install claude >/dev/null 2>&1
  jqok "explicit nulls elsewhere in the file survive install" "$nulls" "$CS"
  "$BIN" uninstall >/dev/null 2>&1
  jqok "explicit nulls survive uninstall too" "$nulls" "$CS"

  # Install then uninstall must leave the file exactly as it was found.
  printf '%s' '{"model":"opus","permissions":{"allow":["Bash"]}}' >"$CS"
  before=$(jq -c . "$CS")
  "$BIN" install claude >/dev/null 2>&1
  "$BIN" uninstall >/dev/null 2>&1
  check "install then uninstall is a round trip" "$before" "$(jq -c . "$CS")"
  rm -f "$CS"
fi

# A user-editable config file must not be able to steer the hook process. This
# is the worst failure mode available: the file is user-editable, and under dash
# a syntax error while sourcing it exits 2, the one code that blocks the turn.
mkdir -p "$CONF_DIR"
for bad_conf in 'exit 3' 'echo leaked' 'NTFY_AGENT_URLS="unterminated'; do
  printf '%s\n' "$bad_conf" >"$conf"
  silent_ok "a config of '$bad_conf'" '{"session_id":"bc"}'
done
rm -f "$conf"
reset_state

# --------------------------------------------------------------------------
say "the installer"
INST="$ROOT/install.sh"

# A curl | sh cut mid-transfer must do nothing at all. The body sits in a brace
# group closed on the last line, so a truncated copy is an unterminated command
# and the shell refuses to run any of it. Cut at 90%, which is past the point
# where an unguarded script would already have created the install directory,
# so this assertion fails if the guard is ever removed.
head -c "$(( $(wc -c <"$INST") * 9 / 10 ))" "$INST" >"$TMP/truncated.sh"
sh "$TMP/truncated.sh" -b "$TMP/trunc-bin" >/dev/null 2>&1
refute "a truncated installer does nothing at all" test -d "$TMP/trunc-bin"

out=$(sh "$INST" -h 2>&1)
missing "help does not leak the script's own source" "set -eu" "$out"
contains "help lists the flags" "--uninstall" "$out"

sh "$INST" --bogus-flag >/dev/null 2>&1
check "an unknown flag exits non-zero" 1 $?
sh "$INST" -b >/dev/null 2>&1
check "a flag missing its argument exits non-zero" 1 $?

# Under Git Bash, curl cannot open the shell's own /d/a/... form of a path.
file_url() {
  if command -v cygpath >/dev/null 2>&1; then printf 'file:///%s' "$(cygpath -m "$1")"
  else printf 'file://%s' "$1"
  fi
}

# Serve the real script from disk so the installer never touches the network.
inst_env() {
  env -i HOME="$TMP/ihome" PATH="$PATH" \
    XDG_CONFIG_HOME="$TMP/ihome/.config" XDG_STATE_HOME="$TMP/ihome/.state" \
    NTFY_AGENT_BASE_URL="$(file_url "$ROOT")" "$@"
}
mkdir -p "$TMP/ihome"
out=$(inst_env sh "$INST" -b "$TMP/ibin" --no-setup 2>&1)
assert "the installer installs an executable script" test -x "$TMP/ibin/ntfy-agent"
contains "the installer warns when the target is not on PATH" "not on your PATH" "$out"
check "the installed script runs" "ntfy-agent $("$BIN" --version | awk '{print $2}')" \
  "$("$TMP/ibin/ntfy-agent" --version)"

# Installing twice must be safe, which is the documented upgrade path.
inst_env sh "$INST" -b "$TMP/ibin" --no-setup >/dev/null 2>&1
check "installing twice succeeds" 0 $?
assert "the script survives a reinstall" test -x "$TMP/ibin/ntfy-agent"

# Every other case here passes --no-setup, so the default path the README shows
# first, which ends by running setup, was never exercised.
out=$(inst_env sh "$INST" -b "$TMP/ibin3" 2>&1)
contains "the default install runs setup" "Subscribe your phone" "$out"
assert "the default install leaves a config behind" \
  test -f "$TMP/ihome/.config/ntfy-agent/config"

# --uninstall is what the README tells people to run to remove it.
env -i HOME="$TMP/ihome" PATH="$TMP/ibin3:$PATH" \
  XDG_CONFIG_HOME="$TMP/ihome/.config" XDG_STATE_HOME="$TMP/ihome/.state" \
  sh "$INST" --uninstall >/dev/null 2>&1
check "--uninstall exits 0" 0 $?
refute "--uninstall removes the installed script" test -e "$TMP/ibin3/ntfy-agent"

# A corrupt or truncated download must be refused rather than installed.
mkdir -p "$TMP/badsrc/bin"
printf '#!/bin/sh\nif true; then\n' >"$TMP/badsrc/bin/ntfy-agent"
out=$(inst_env NTFY_AGENT_BASE_URL="$(file_url "$TMP/badsrc")" sh "$INST" \
  -b "$TMP/badbin" --no-setup 2>&1)
check "an incomplete download is refused" 1 $?
refute "an incomplete download installs nothing" test -e "$TMP/badbin/ntfy-agent"

printf '<html>404</html>\n' >"$TMP/badsrc/bin/ntfy-agent"
inst_env NTFY_AGENT_BASE_URL="$(file_url "$TMP/badsrc")" sh "$INST" \
  -b "$TMP/badbin2" --no-setup >/dev/null 2>&1
check "an error page is not installed as a script" 1 $?

# --------------------------------------------------------------------------
printf '\n%s\n' "----------------------------------------"
printf 'passed %s, failed %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
