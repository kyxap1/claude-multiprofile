#!/usr/bin/env bash
# End-to-end check of install, migrate, add, dispatch, login isolation, statusline
# and rollback against a throwaway HOME. Claude Code and the macOS `security` tool
# are replaced by mocks, so nothing real is logged in or written to a Keychain.
# Run via `make test` (Docker) or directly on a disposable machine such as CI.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HOME="$(mktemp -d)"
HOME="$(cd "$HOME" && pwd -P)"
export HOME
MOCKS="$HOME/mocks"
export PATH="$HOME/bin:$MOCKS:$HOME/.local/bin:$PATH"
export KEYCHAIN="$HOME/keychain.txt"
P="$REPO/claude-profiles.sh"
ME="$(id -un)"

step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
want_eq() { [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"; }
want_has() { case "$1" in *"$2"*) ;; *) fail "$3: '$2' not in output: $1" ;; esac; }
want_not() { case "$1" in *"$2"*) fail "$3: '$2' unexpectedly in output: $1" ;; esac; }

# Claude Code mock: `auth status` answers from the profile's credentials file,
# anything else reports what the dispatcher handed over.
mkdir -p "$HOME/.local/bin" "$MOCKS"
cat > "$HOME/.local/bin/claude" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "auth status" ]; then
  creds="$CLAUDE_CONFIG_DIR/.credentials.json"
  if [ -f "$creds" ]; then jq -c '{loggedIn: true, email}' "$creds"; else echo '{"loggedIn":false}'; fi
  exit 0
fi
echo "dir=$CLAUDE_CONFIG_DIR model=${ANTHROPIC_MODEL:-}"
EOF

# macOS `security` mock: a Keychain as one "account|service" line per item.
cat > "$MOCKS/security" <<'EOF'
#!/bin/sh
cmd="$1"; shift
while [ $# -gt 0 ]; do
  case "$1" in -a) acct="$2"; shift ;; -s) svc="$2"; shift ;; esac
  shift
done
touch "$KEYCHAIN"
case "$cmd" in
  add-generic-password) echo "$acct|$svc" >> "$KEYCHAIN" ;;
  find-generic-password) grep -qxF "$acct|$svc" "$KEYCHAIN" ;;
  delete-generic-password)
    grep -qxF "$acct|$svc" "$KEYCHAIN" || exit 44
    grep -vxF "$acct|$svc" "$KEYCHAIN" > "$KEYCHAIN.new" || :
    mv "$KEYCHAIN.new" "$KEYCHAIN" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$HOME/.local/bin/claude" "$MOCKS/security"

# What /login leaves behind: a credentials file in the profile (Linux) and a
# Keychain item named after the resolved profile dir (macOS).
service_for() { printf 'Claude Code-credentials-%s' "$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"; }
fake_login() {
  jq -n --arg e "$2" '{email: $e}' > "$1/.credentials.json"
  security add-generic-password -a "$ME" -s "$(service_for "$1")"
}

# A single-account ~/.claude as Claude Code leaves it.
mkdir -p "$HOME/.claude/skills/demo" "$HOME/.claude/projects/p1"
echo '# rules' > "$HOME/.claude/CLAUDE.md"
echo '{"theme":"dark"}' > "$HOME/.claude/settings.json"
echo '{"email":"work@example.com"}' > "$HOME/.claude/.credentials.json"
echo 'line' > "$HOME/.claude/history.jsonl"
echo '{"global":true}' > "$HOME/.claude.json"
security add-generic-password -a "$ME" -s "Claude Code-credentials"

step "install"
"$P" install
[ -x "$HOME/bin/claude" ] || fail "wrapper not installed"
[ -x "$HOME/.claude/statusline.sh" ] || fail "statusline not installed"
# shellcheck disable=SC2088
want_eq "$(jq -r .statusLine.command "$HOME/.claude/settings.json")" '~/.claude/statusline.sh' "statusLine"
want_eq "$(jq -r .statusLine.refreshInterval "$HOME/.claude/settings.json")" "60" "refreshInterval"
want_eq "$(jq -r .theme "$HOME/.claude/settings.json")" "dark" "existing settings kept"
want_has "$("$P" install)" "already has a statusLine" "install is idempotent"
s="$HOME/.claude/settings.json"
jq 'del(.statusLine.refreshInterval)' "$s" > "$s.new" && mv "$s.new" "$s"
"$P" install >/dev/null
want_eq "$(jq -r .statusLine.refreshInterval "$s")" "60" "refreshInterval added to an older install"
jq '.statusLine.command = "my-own.sh" | del(.statusLine.refreshInterval)' "$s" > "$s.new" && mv "$s.new" "$s"
"$P" install >/dev/null
want_eq "$(jq -c .statusLine "$s")" '{"type":"command","command":"my-own.sh"}' "someone else's statusLine untouched"
jq '.statusLine = {type: "command", command: "~/.claude/statusline.sh", refreshInterval: 60}' "$s" > "$s.new" && mv "$s.new" "$s"

step "reset countdown"
eval "$(sed -n '/^fmt_countdown() {/,/^}/p' "$REPO/statusline.sh")"
for c in -5:'<1m' 59:'<1m' 60:1m 3599:59m 3600:1h 3900:1h5m 7199:1h59m 17999:4h59m \
         86399:23h59m 86400:1d 108000:1d6h 172799:1d23h 604799:6d23h; do
  want_eq "$(fmt_countdown "${c%%:*}")" "${c#*:}" "countdown ${c%%:*}s"
done

step "migrate --dry-run changes nothing"
before="$(find "$HOME" | sort)"
"$P" migrate --dry-run work private
want_eq "$(find "$HOME" | sort)" "$before" "dry run touched files"

step "migrate work private"
echo y | "$P" migrate work private
for f in history.jsonl .credentials.json projects/p1 .claude.json; do
  [ -e "$HOME/.claude-work/$f" ] || fail "$f not moved to work"
done
[ ! -e "$HOME/.claude/history.jsonl" ] || fail "history left in shared dir"
[ ! -e "$HOME/.claude.json" ] || fail "global config left in HOME"
[ -f "$HOME/.claude/CLAUDE.md" ] || fail "CLAUDE.md left shared dir"
for p in work private; do
  want_eq "$(readlink "$HOME/.claude-$p/settings.json")" "$HOME/.claude/settings.json" "$p settings link"
  want_eq "$(readlink "$HOME/.claude-$p/skills")" "$HOME/.claude/skills" "$p skills link"
done
[ ! -e "$HOME/.claude-private/history.jsonl" ] || fail "private not empty"
want_eq "$(readlink "$HOME/.claude-default")" ".claude-work" "default link"

step "dispatch"
want_eq "$(claude-work)" "dir=$HOME/.claude-work model=" "claude-work"
want_eq "$(claude)" "dir=$HOME/.claude-work model=" "bare claude follows default, resolved"
want_eq "$(CLAUDE_CONFIG_DIR="$HOME/.claude-private" claude)" "dir=$HOME/.claude-private model=" "CLAUDE_CONFIG_DIR wins"

step "add with model"
"$P" add private2 sonnet
want_eq "$(claude-private2)" "dir=$HOME/.claude-private2 model=sonnet" "per-profile model"
want_eq "$(ANTHROPIC_MODEL=opus claude-private2)" "dir=$HOME/.claude-private2 model=opus" "env model wins"

step "refusals"
! "$P" add Bad 2>/dev/null || fail "accepted uppercase name"
! "$P" add default 2>/dev/null || fail "accepted 'default'"
! "$P" add work 2>/dev/null || fail "re-created existing profile"
! "$P" migrate x 2>/dev/null </dev/null || fail "migrated twice"

step "check"
out="$("$P" check)" || fail "check failed: $out"
want_has "$out" "ok    PATH" "check PATH"
want_has "$out" "profile private2 -> $HOME/.claude-private2 (model sonnet)" "check lists profile"

step "login isolation and statusline"
status() {
  local json
  json='{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/x/repo"},"session_id":"'"$2"'",
    "cost":{"total_cost_usd":1.5,"total_duration_ms":65000},"effort":{"level":"high"},
    "context_window":{"used_percentage":42,"total_input_tokens":15600,"total_output_tokens":1200000},
    "rate_limits":{"five_hour":{"used_percentage":80,"resets_at":9999999999}}}'
  printf '%s' "$json" | CLAUDE_CONFIG_DIR="$HOME/.claude-$1" "$HOME/.claude/statusline.sh"
}
fake_login "$HOME/.claude-work" work@example.com
out="$(status work s1)"
# shellcheck disable=SC2016
for s in Opus repo work work@example.com '$1.50' 't:15k/1.2M' '42%' ':80%'; do
  want_has "$out" "$s" "statusline segment"
done
want_not "$(status private s1)" "@example.com" "logged-out profile shows another profile's email"
fake_login "$HOME/.claude-private" private@example.com
out="$(status private s2)"
want_has "$out" "private@example.com" "private email after login"
want_not "$out" "work@example.com" "work email leaked into private"
want_has "$(status work s1)" "work@example.com" "work cache survives private session"
fake_login "$HOME/.claude-private2" side@example.com
out="$(status private2 s3)"
want_has "$out" "side@example.com" "second private account shows its own email"
want_not "$out" "private@example.com" "private email leaked into private2"

step "profile colours"
c_private="$(status private s2 | grep -o '38;5;[0-9]*m [^ ]*  private ' | grep -o '38;5;[0-9]*')"
c_private2="$(status private2 s3 | grep -o '38;5;[0-9]*m [^ ]*  private2 ' | grep -o '38;5;[0-9]*')"
[ -n "$c_private" ] && [ -n "$c_private2" ] || fail "could not read profile colours"
[ "$c_private" != "$c_private2" ] || fail "private and private2 share colour $c_private"
# Slot 9 is colour 74 with the ring icon; the pin file needs no trailing newline.
printf 9 > "$HOME/.claude-private2/statusline-style"
want_has "$(status private2 s3)" $'38;5;74m \xee\xbc\x8b  private2 ' "pinned slot"
echo junk > "$HOME/.claude-private2/statusline-style"
want_has "$(status private2 s3)" "$c_private2"'m ' "invalid pin falls back to the hash"
rm "$HOME/.claude-private2/statusline-style"

step "rollback"
backups=("$HOME"/.claude-migration-backup-*)
"${backups[0]}/ROLLBACK.sh"
[ -f "$HOME/.claude/history.jsonl" ] || fail "history not restored"
[ -f "$HOME/.claude.json" ] || fail "global config not restored"
for p in work private; do
  [ ! -e "$HOME/.claude-$p" ] || fail ".claude-$p left behind"
  [ ! -e "$HOME/bin/claude-$p" ] || fail "claude-$p left behind"
done
[ ! -e "$HOME/.claude-default" ] || fail "default link left behind"
# Profiles added after migrate are not part of the rollback and keep their login.
[ -d "$HOME/.claude-private2" ] || fail "rollback removed a profile added later"
want_eq "$(cat "$KEYCHAIN")" "$ME|Claude Code-credentials
$ME|$(service_for "$HOME/.claude-private2")" "Keychain after rollback: pre-migration item plus the later profile"

printf '\nall passed (bash %s)\n' "$BASH_VERSION"
