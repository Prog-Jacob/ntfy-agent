#!/bin/sh
# ntfy-agent installer.
#
#   curl -fsSL https://raw.githubusercontent.com/Prog-Jacob/ntfy-agent/main/install.sh | sh
#
# Installs one shell script, then tells you what to do next. No compiler, no
# package manager, no daemon.

{

set -eu

REPO="${NTFY_AGENT_REPO:-Prog-Jacob/ntfy-agent}"
REF=""
BINDIR=""
NO_SETUP=0
ASSUME_YES=0
UNINSTALL=0

usage() {
  cat <<'EOF'
ntfy-agent installer.

  -b <dir>     install directory (default: the first writable of
               ~/.local/bin, /usr/local/bin)
  -v <ref>     git ref to install (default: the latest release, else main)
  -y, --yes    accept defaults, never prompt
  -n, --no-setup
               install the script only, skip generating a config
  --uninstall  remove the script, the hooks, the config and the state
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -b) [ $# -ge 2 ] || { printf 'install: -b needs a directory\n' >&2; exit 1; }
        BINDIR=$2; shift 2 ;;
    -v) [ $# -ge 2 ] || { printf 'install: -v needs a git ref\n' >&2; exit 1; }
        REF=$2; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -n|--no-setup) NO_SETUP=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

die() { printf 'install: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have curl || have wget || die "need curl or wget. Install one, then re-run this script."

# Download <url> to <dest>, or to stdout when <dest> is omitted. An https URL
# refuses a downgrade or a redirect to plain http, on both clients. The plain
# branch is for a test pointing NTFY_AGENT_BASE_URL at a local file.
fetch() {
  dest=${2:--}
  if have curl; then
    case "$1" in
      https://*) curl --proto '=https' --tlsv1.2 -fsSL "$1" -o "$dest" ;;
      *)         curl -fsSL "$1" -o "$dest" ;;
    esac
  else
    case "$1" in
      https://*) wget -q --https-only --secure-protocol=TLSv1_2 -O "$dest" "$1" ;;
      *)         wget -qO "$dest" "$1" ;;
    esac
  fi
}

if [ "$UNINSTALL" = 1 ]; then
  found=$(command -v ntfy-agent 2>/dev/null || echo "")
  [ -n "$found" ] || die "ntfy-agent is not on your PATH. Remove it by hand, or pass -b <dir>."
  "$found" uninstall || true
  rm -f "$found" && printf 'Removed %s\n' "$found"
  printf 'Config and state are kept. Remove them with:\n'
  printf '  rm -rf "%s" "%s"\n' \
    "${XDG_CONFIG_HOME:-$HOME/.config}/ntfy-agent" \
    "${XDG_STATE_HOME:-$HOME/.local/state}/ntfy-agent"
  exit 0
fi

if [ -n "$BINDIR" ]; then
  mkdir -p "$BINDIR" || die "cannot create $BINDIR"
else
  # Prefer a user-writable dir so the install never needs sudo.
  for d in "$HOME/.local/bin" /usr/local/bin; do
    if [ -d "$d" ] && [ -w "$d" ]; then BINDIR=$d; break; fi
  done
  if [ -z "$BINDIR" ]; then
    BINDIR="$HOME/.local/bin"
    mkdir -p "$BINDIR" || die "cannot create $BINDIR"
  fi
fi

BASE="${NTFY_AGENT_BASE_URL:-}"
# Track the latest release, not whatever main happens to be. Falls back to main
# when there is no release yet or the API is unreachable.
if [ -z "$REF" ]; then
  if [ -n "$BASE" ]; then
    REF=main
  else
    REF=$(fetch "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
          | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
          | head -1)
    [ -n "$REF" ] || REF=main
  fi
fi
: "${BASE:=https://raw.githubusercontent.com/$REPO/$REF}"
URL="$BASE/bin/ntfy-agent"

# Temp file inside the destination dir, not $TMPDIR, so the final mv is a
# same-filesystem rename and cannot leave a half-written executable behind.
TMP=$(mktemp "$BINDIR/.ntfy-agent.XXXXXX") || die "cannot write to $BINDIR"
trap 'rm -f "$TMP"' EXIT INT TERM

printf 'Downloading ntfy-agent (%s)\n' "$REF"
fetch "$URL" "$TMP" || die "download failed: $URL"

# Not integrity, just a truncation and wrong-file canary: a partial download
# fails the syntax check, and an HTML error page fails the shebang check.
head -1 "$TMP" | grep -q '^#!/bin/sh' \
  || die "downloaded file is not ntfy-agent. Check that $REF exists."
sh -n "$TMP" || die "downloaded script is incomplete. Re-run to try again."

chmod 755 "$TMP"   # before the rename, so it is never briefly world-writable
mv "$TMP" "$BINDIR/ntfy-agent"
trap - EXIT INT TERM
printf 'Installed %s\n' "$BINDIR/ntfy-agent"

# shellcheck disable=SC2016  # $PATH stays literal, the user pastes it verbatim
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) printf '\nNOTE: %s is not on your PATH. Add this to your shell profile:\n  export PATH="%s:$PATH"\n' \
       "$BINDIR" "$BINDIR" ;;
esac

[ "$NO_SETUP" = 1 ] && exit 0

printf '\n'
# setup prompts, reading /dev/tty itself because piping this script into sh
# leaves stdin holding the script. -y turns every prompt into its default.
[ "$ASSUME_YES" = 1 ] && export NTFY_AGENT_YES=1
"$BINDIR/ntfy-agent" setup </dev/null

} # The brace group opened at the top. Truncation cannot reach this line.
