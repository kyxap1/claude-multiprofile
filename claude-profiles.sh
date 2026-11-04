#!/usr/bin/env bash
# Several Claude Code accounts on one shared config.
#
#   ~/.claude          shared config: CLAUDE.md, settings, skills, hooks, plugins
#   ~/.claude-NAME     one account's state: credentials, history, sessions, .claude.json
#   ~/bin/claude-NAME  symlink to the ~/bin/claude dispatcher, runs that profile
#
# Run without arguments for the full help text.
#
# Claude Code keys everything off CLAUDE_CONFIG_DIR. On macOS that includes the
# Keychain item: with the variable set it is "Claude Code-credentials-<sha256(dir)[0:8]>",
# without it the plain "Claude Code-credentials". So each profile logs in on its own,
# and the account that already lives in ~/.claude needs one fresh /login after migrate.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SHARED_DIR="$HOME/.claude"
DEFAULT_DIR="$HOME/.claude-default"
BIN_DIR="$HOME/bin"
WRAPPER="$BIN_DIR/claude"
REAL="${CLAUDE_REAL:-$HOME/.local/bin/claude}"
GLOBAL_CONFIG="$HOME/.claude.json"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$HOME/.claude-migration-backup-$STAMP"

# Stays in ~/.claude. Everything else there is per-account state and moves
# into the first profile on migrate.
SHARED_ENTRIES=(
  CLAUDE.md settings.json keybindings.json statusline.sh
  skills commands agents hooks plugins themes output-styles
)

# Symlinked into every profile: the subset Claude Code looks up inside
# CLAUDE_CONFIG_DIR. Hooks and the statusline are referenced by path from
# settings.json, so they need no link.
LINKED_ENTRIES=(CLAUDE.md settings.json keybindings.json skills commands agents plugins themes output-styles)

DRY_RUN=0

# Every mutating command goes through this, so --dry-run prints instead of acting.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf 'would  %s\n' "$*"
  else
    "$@"
  fi
}

# APFS clone on macOS costs ~no disk; elsewhere a plain archive copy.
clone_copy() {
  if [ "$(uname)" = Darwin ]; then
    run /bin/cp -Rc "$1" "$2"
  else
    run cp -a "$1" "$2"
  fi
}

is_shared() {
  local name="$1" entry
  for entry in "${SHARED_ENTRIES[@]}"; do
    [ "$name" = "$entry" ] && return 0
  done
  return 1
}

# The name lands in a path and a command name; "default" is taken by ~/.claude-default.
check_name() {
  if ! printf '%s' "$1" | grep -qE '^[a-z0-9][a-z0-9-]*$' || [ "$1" = default ]; then
    echo "bad profile name '$1': lowercase letters, digits, dashes; not 'default'" >&2
    exit 1
  fi
}

link_shared() {
  local profile_dir="$1" name
  for name in "${LINKED_ENTRIES[@]}"; do
    [ -e "$SHARED_DIR/$name" ] || continue
    run ln -sfn "$SHARED_DIR/$name" "$profile_dir/$name"
  done
}

# The dispatcher picks the profile from its own basename, so a profile command
# is just another symlink to it. Aliases would be wrong: bash re-expands aliases
# inside an alias body, so a trailing `claude` picks up `alias claude=...`.
link_profile() {
  run ln -sfn claude "$BIN_DIR/claude-$1"
}

write_model() {
  local dir="$1" model="${2:-}"
  [ -n "$model" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then
    printf 'would  write %s/model (%s)\n' "$dir" "$model"
  else
    printf '%s\n' "$model" > "$dir/model"
  fi
}

keychain_service() {
  printf 'Claude Code-credentials-%s' "$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"
}

# Copies a file into place, keeping a differing original as NAME.bak-STAMP.
place() {
  local src="$1" dst="$2"
  if [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then
    run mv "$dst" "$dst.bak-$STAMP"
  fi
  run cp "$src" "$dst"
  run chmod +x "$dst"
}

path_report() {
  local found
  found="$(command -v claude || true)"
  if [ "$found" = "$WRAPPER" ]; then
    echo "ok    PATH: claude resolves to $WRAPPER"
  else
    echo "FIX   PATH: claude resolves to '${found:-nothing}', not $WRAPPER"
    echo "      add to your shell rc, then open a new shell:"
    echo "        export PATH=\"\$HOME/bin:\$PATH\""
  fi
  if [ -x "$REAL" ]; then
    echo "ok    real Claude Code binary: $REAL"
  else
    echo "FIX   no Claude Code binary at $REAL - install it, or export CLAUDE_REAL=/path/to/claude"
  fi
}

install() {
  case "${1:-}" in
    --dry-run | -n) DRY_RUN=1 ;;
    "") ;;
    *) echo "usage: $0 install [--dry-run]" >&2; exit 1 ;;
  esac
  command -v jq >/dev/null || { echo "jq is required (statusline and settings edit)" >&2; exit 1; }

  run mkdir -p "$BIN_DIR" "$SHARED_DIR"
  place "$SRC_DIR/bin/claude" "$WRAPPER"
  place "$SRC_DIR/statusline.sh" "$SHARED_DIR/statusline.sh"

  local settings="$SHARED_DIR/settings.json"
  if [ -f "$settings" ] && jq -e 'has("statusLine")' "$settings" >/dev/null; then
    echo "keep  $settings already has a statusLine block - left as is"
  elif [ "$DRY_RUN" = 1 ]; then
    echo "would  add statusLine -> ~/.claude/statusline.sh to $settings"
  else
    local current='{}'
    [ -f "$settings" ] && current="$(cat "$settings")"
    printf '%s' "$current" \
      | jq '. + {statusLine: {type: "command", command: "~/.claude/statusline.sh"}}' \
      > "$settings.tmp-$STAMP"
    mv "$settings.tmp-$STAMP" "$settings"
    echo "added statusLine to $settings"
  fi
  echo
  path_report
}

require_wrapper() {
  [ -d "$SHARED_DIR" ] || { echo "no $SHARED_DIR" >&2; exit 1; }
  [ -x "$WRAPPER" ] || { echo "no $WRAPPER - run '$0 install' first" >&2; exit 1; }
}

add_profile() {
  local name="${1:-}" model="${2:-}" dir
  [ -n "$name" ] || { echo "usage: $0 add NAME [MODEL]" >&2; exit 1; }
  check_name "$name"
  require_wrapper
  dir="$HOME/.claude-$name"
  [ -e "$dir" ] && { echo "$dir already exists" >&2; exit 1; }

  mkdir -m 700 "$dir"
  link_shared "$dir"
  link_profile "$name"
  write_model "$dir" "$model"

  cat <<EOF
Created $dir sharing config from $SHARED_DIR.

Next
  claude-$name -> /login with that account
EOF
}

migrate() {
  local answer path name dir service first
  local -a names=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run | -n) DRY_RUN=1 ;;
      -*) echo "unknown flag $1" >&2; exit 1 ;;
      *) names+=("$1") ;;
    esac
    shift
  done
  [ ${#names[@]} -gt 0 ] || { echo "usage: $0 migrate [--dry-run] NAME [NAME...]" >&2; exit 1; }
  for name in "${names[@]}"; do check_name "$name"; done
  require_wrapper
  first="${names[0]}"
  for name in "${names[@]}"; do
    dir="$HOME/.claude-$name"
    [ -e "$dir" ] && { echo "$dir already exists - refusing (use '$0 add NAME' instead)" >&2; exit 1; }
  done
  [ -e "$DEFAULT_DIR" ] && { echo "$DEFAULT_DIR already exists - already migrated?" >&2; exit 1; }

  echo "Plan$([ "$DRY_RUN" = 1 ] && echo ' (dry run)')"
  echo "  backup    $SHARED_DIR, $GLOBAL_CONFIG -> $BACKUP_DIR"
  echo "  move      per-account state from $SHARED_DIR -> $HOME/.claude-$first"
  echo "  move      $GLOBAL_CONFIG -> $HOME/.claude-$first/.claude.json"
  for name in "${names[@]:1}"; do
    echo "  create    $HOME/.claude-$name (empty, needs /login)"
  done
  echo "  default   $DEFAULT_DIR -> .claude-$first (bare 'claude')"
  echo "  rollback  $BACKUP_DIR/ROLLBACK.sh"
  echo
  echo "Moves out of $SHARED_DIR:"
  shopt -s dotglob nullglob
  for path in "$SHARED_DIR"/*; do
    name="$(basename "$path")"
    is_shared "$name" || echo "  $name"
  done
  shopt -u dotglob nullglob
  echo

  if [ "$DRY_RUN" = 0 ]; then
    read -r -p "Proceed? [y/N] " answer
    case "$answer" in
      y | Y) ;;
      *) echo "aborted"; exit 1 ;;
    esac
  fi

  run mkdir -p "$BACKUP_DIR"
  clone_copy "$SHARED_DIR" "$BACKUP_DIR/claude"
  [ -f "$GLOBAL_CONFIG" ] && clone_copy "$GLOBAL_CONFIG" "$BACKUP_DIR/claude.json"

  if [ "$DRY_RUN" = 1 ]; then
    echo "would  write $BACKUP_DIR/ROLLBACK.sh"
  else
    {
      echo '#!/usr/bin/env bash'
      echo '# Restores the pre-migration state from this backup.'
      echo 'set -euo pipefail'
      printf 'rm -rf %q %q' "$SHARED_DIR" "$DEFAULT_DIR"
      for name in "${names[@]}"; do printf ' %q' "$HOME/.claude-$name"; done
      echo
      printf 'cp -a %q %q\n' "$BACKUP_DIR/claude" "$SHARED_DIR"
      [ -f "$GLOBAL_CONFIG" ] && printf 'cp -a %q %q\n' "$BACKUP_DIR/claude.json" "$GLOBAL_CONFIG"
      printf 'rm -f'
      for name in "${names[@]}"; do printf ' %q' "$BIN_DIR/claude-$name"; done
      echo
      echo 'if command -v security >/dev/null; then'
      # $(id -un) is meant to expand when ROLLBACK.sh runs, not now.
      # shellcheck disable=SC2016
      for name in "${names[@]}"; do
        service="$(keychain_service "$HOME/.claude-$name")"
        printf '  if security find-generic-password -a "$(id -un)" -s %q >/dev/null 2>&1; then\n' "$service"
        printf '    security delete-generic-password -a "$(id -un)" -s %q >/dev/null\n' "$service"
        printf '  fi\n'
      done
      echo 'fi'
      echo 'echo "rolled back - open a new shell"'
    } > "$BACKUP_DIR/ROLLBACK.sh"
    chmod +x "$BACKUP_DIR/ROLLBACK.sh"
  fi

  for name in "${names[@]}"; do
    run mkdir -m 700 "$HOME/.claude-$name"
  done

  shopt -s dotglob nullglob
  for path in "$SHARED_DIR"/*; do
    name="$(basename "$path")"
    is_shared "$name" || run mv "$path" "$HOME/.claude-$first/$name"
  done
  shopt -u dotglob nullglob
  [ -f "$GLOBAL_CONFIG" ] && run mv "$GLOBAL_CONFIG" "$HOME/.claude-$first/.claude.json"

  for name in "${names[@]}"; do
    link_shared "$HOME/.claude-$name"
    link_profile "$name"
  done
  run ln -sfn ".claude-$first" "$DEFAULT_DIR"

  if [ "$DRY_RUN" = 1 ]; then
    echo
    echo "Dry run - nothing changed."
    return
  fi

  echo
  echo "Done. Backup: $BACKUP_DIR (rollback: $BACKUP_DIR/ROLLBACK.sh)"
  echo
  echo "Next, one /login per profile:"
  for name in "${names[@]}"; do echo "  claude-$name"; done
  echo
  path_report
}

check() {
  local link name dir entry ok=1
  path_report
  echo
  for link in "$BIN_DIR"/claude-*; do
    [ -L "$link" ] && [ "$(readlink "$link")" = claude ] || continue
    name="${link##*/claude-}"
    dir="$HOME/.claude-$name"
    if [ ! -d "$dir" ]; then
      echo "FIX   $link has no profile dir $dir"; ok=0; continue
    fi
    for entry in "${LINKED_ENTRIES[@]}"; do
      [ -e "$SHARED_DIR/$entry" ] || continue
      if [ ! -L "$dir/$entry" ]; then
        echo "WARN  $dir/$entry is not a symlink - diverged from $SHARED_DIR"; ok=0
      fi
    done
    echo "ok    profile $name -> $dir$([ -f "$dir/model" ] && echo " (model $(head -n 1 "$dir/model"))")"
  done
  [ -L "$DEFAULT_DIR" ] && echo "ok    default -> $(readlink "$DEFAULT_DIR")"
  [ "$ok" = 1 ]
}

usage() {
  cat <<EOF
Claude Code profile manager - several accounts, one shared config.

Usage
  $0 install [--dry-run]           copy the dispatcher to $WRAPPER and statusline.sh to
                                   $SHARED_DIR, add the statusLine block to settings.json
  $0 migrate [--dry-run] NAME...   one-time split of $SHARED_DIR: the current account
                                   moves to ~/.claude-NAME (first name), the other names
                                   start empty; the first is the default
  $0 add NAME [MODEL]              another profile: ~/.claude-NAME + $BIN_DIR/claude-NAME,
                                   MODEL (e.g. opus, sonnet) is that profile's default model
  $0 check                         verify PATH, profile links and the default

Commands in $BIN_DIR, all symlinks to the $WRAPPER dispatcher
  claude          whatever $DEFAULT_DIR points at, unless CLAUDE_CONFIG_DIR is set
  claude-NAME     that profile

Not shared between profiles: history, sessions, projects, .claude.json and therefore
user-scope MCP servers. Each profile needs its own /login.
EOF
}

case "${1:-help}" in
  install) shift; install "$@" ;;
  migrate) shift; migrate "$@" ;;
  add) shift; add_profile "$@" ;;
  check) check ;;
  help | -h | --help) usage ;;
  *) usage >&2; exit 1 ;;
esac
