#!/usr/bin/env bash
# Runs inside the image from run.sh: renders the real statusline.sh for two
# made-up profiles into docs/statusline.png.
set -euo pipefail

export HOME=/home/demo
mkdir -p "$HOME/bin" /src
cat > "$HOME/bin/claude" <<'EOF'
#!/bin/sh
case "$CLAUDE_CONFIG_DIR" in
  *work) echo '{"email":"dev@acme.example"}' ;;
  *private2) echo '{"email":"side@example.com"}' ;;
  *) echo '{"email":"me@example.com"}' ;;
esac
EOF
chmod +x "$HOME/bin/claude"
export PATH="$HOME/bin:$PATH"
git config --global init.defaultBranch main
git config --global user.email demo@example.com
git config --global user.name demo

now=$(date +%s)

# name dir branch json
render() {
  local name="$1" dir="$2" branch="$3" json="$4"
  mkdir -p "$HOME/.claude-$name" "/src/$dir"
  (cd "/src/$dir" && git init -q && git checkout -q -b "$branch")
  (cd "/src/$dir" && printf '%s' "$json" | CLAUDE_CONFIG_DIR="$HOME/.claude-$name" bash /repo/statusline.sh) \
    | python3 /repo/docs/screenshot/ansi2html.py
}

work=$(render work billing-api feat/PAY-2041-retry-failed-webhooks '{
  "model":{"display_name":"Opus 5.5"},"workspace":{"current_dir":"/src/billing-api"},"session_id":"a1",
  "cost":{"total_cost_usd":26.37,"total_duration_ms":2832000},"effort":{"level":"medium"},
  "context_window":{"used_percentage":14,"total_input_tokens":28000,"total_output_tokens":182},
  "rate_limits":{"five_hour":{"used_percentage":82,"resets_at":'$((now + 2*3600 + 1800))'},
                 "seven_day":{"used_percentage":41,"resets_at":'$((now + 3*86400 + 5*3600))'}}}')

private=$(render private dotfiles main '{
  "model":{"display_name":"Opus 5.5"},"workspace":{"current_dir":"/src/dotfiles"},"session_id":"b2",
  "cost":{"total_cost_usd":2.75,"total_duration_ms":1084000},"effort":{"level":"high"},
  "context_window":{"used_percentage":34,"total_input_tokens":68000,"total_output_tokens":246},
  "rate_limits":{"five_hour":{"used_percentage":96,"resets_at":'$((now + 1800))'},
                 "seven_day":{"used_percentage":83,"resets_at":'$((now + 1*86400 + 3*3600))'}}}')

# Fresh session on a second private account: everything at its starting point.
private2=$(render private2 side-project main '{
  "model":{"display_name":"Sonnet 5.5"},"workspace":{"current_dir":"/src/side-project"},"session_id":"c3",
  "cost":{"total_cost_usd":0.03,"total_duration_ms":14000},"effort":{"level":"low"},
  "context_window":{"used_percentage":1,"total_input_tokens":2000,"total_output_tokens":12},
  "rate_limits":{"five_hour":{"used_percentage":1,"resets_at":'$((now + 4*3600 + 3540))'},
                 "seven_day":{"used_percentage":1,"resets_at":'$((now + 6*86400 + 23*3600))'}}}')

# Permission-mode line under the prompt: drawn by Claude Code itself, imitated here.
auto='<div class="mode auto">&#x25B6;&#x25B6; auto mode on <span class="hint">(shift+tab to cycle) &#xB7; PR <u>#128</u></span></div>'
manual='<div class="mode manual"><span class="pause">&#x275A;&#x275A;</span> manual mode on <span class="hint">&#xB7; PR <u>#7</u></span></div>'
plan='<div class="mode plan"><span class="pause">&#x275A;&#x275A;</span> plan mode on <span class="hint">(shift+tab to cycle)</span></div>'

pane() {
  cat <<EOF
<div class="pane">
<div class="cmd">\$ claude-$1</div>
<div class="rule"></div>
<div class="line"><span class="dim">&#x276F;</span> <span class="cursor">&nbsp;</span></div>
<div class="rule"></div>
<div class="status">$2</div>
$3
</div>
EOF
}

cat > /tmp/statusline.html <<EOF
<!doctype html><meta charset="utf-8">
<style>
  html,body { height:auto; } body { margin:0; background:#121212; font-family:'JetBrainsMono Nerd Font','Noto Sans Symbols 2','DejaVu Sans Mono',monospace; font-size:15px; color:#bcbcbc; }
  .pane { background:#1c1c1c; margin:16px; padding:10px 14px 14px; border-radius:8px; width:1110px; }
  .cmd { color:#8a8a8a; margin-bottom:8px; }
  .rule { border-top:1px solid #4e4e4e; margin:6px 0; }
  .line { padding:4px 0; }
  .cursor { background:#d0d0d0; }
  .status { white-space:pre; line-height:1.35; margin:10px 0 4px 18px; }
  .mode { margin-left:18px; }
  .auto { color:#afd700; }
  .manual { color:#d0d0d0; }
  .plan { color:#5fafaf; }
  .dim { color:#8a8a8a; }
  .hint { color:#bcbcbc; }
  .pause { font-size:0.7em; vertical-align:0.12em; }
  .hint u { color:#d0d0d0; }
</style>
$(pane work "$work" "$auto")
$(pane private "$private" "$manual")
$(pane private2 "$private2" "$plan")
EOF

timeout 60 chromium --headless --no-sandbox --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --virtual-time-budget=1000 --window-size=1170,700 \
  --screenshot=/out/statusline.png file:///tmp/statusline.html 2>/dev/null
echo rendered
