#!/usr/bin/env bash
# ANSI colour codes are built into printf formats on purpose; RGB triples split on spaces.
# shellcheck disable=SC2059,SC2207,SC2086
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name')
DIR=$(echo "$input" | jq -r '.workspace.current_dir')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
EFFORT=$(echo "$input" | jq -r '.effort.level // "?"')
INPUT_T=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
OUTPUT_T=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
RATE_5H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
WEEK=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
RESETS_5H=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
RESETS_7D=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
SESSION_ID=$(echo "$input" | jq -r '.session_id // empty')

# `claude auth status` is a local, fast (~150ms) call, but still too slow to run on
# every statusline refresh. Cache the email against the session_id and only re-run
# it when a new session starts.
# One cache per profile, so sessions of different accounts don't evict each other.
# ponytail: no lock — two sessions of one profile can bounce it and each pay the refresh.
ACCOUNT_CACHE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline-account-cache"
EMAIL=""
if [ -n "$SESSION_ID" ]; then
  CACHED_SESSION=""
  [ -f "$ACCOUNT_CACHE" ] && IFS='|' read -r CACHED_SESSION EMAIL < "$ACCOUNT_CACHE"
  if [ "$CACHED_SESSION" != "$SESSION_ID" ]; then
    EMAIL=$(claude auth status --json 2>/dev/null | jq -r '.email // empty')
    [ -n "$EMAIL" ] && echo "${SESSION_ID}|${EMAIL}" > "$ACCOUNT_CACHE"
  fi
fi

ACCOUNT=""
if [[ -n "$CLAUDE_CONFIG_DIR" ]]; then
  ACCOUNT="${CLAUDE_CONFIG_DIR##*.claude-}"
fi

ACCOUNT_COLOR=""
ACCOUNT_ICON=""
if [ -n "$ACCOUNT" ]; then
  # hue sweep 0-270deg only (skips the hot-pink/magenta band), reordered ~108deg apart per hash step
  ACCOUNT_PALETTE=(167 149 80 134 185 79 62 179 77 74)
  # fa-user_astronaut, _ninja, _secret, fa-robot, _graduate, _doctor, _nurse, _injured, fa-person_digging, fa-ring
  ACCOUNT_ICONS=($'\xee\xb7\x85' $'\xee\xb7\x8e' $'\xef\x88\x9b' $'\xee\xb8\x8d' $'\xee\xb7\x8b' $'\xef\x83\xb0' $'\xee\xbe\x92' $'\xee\xbc\x93' $'\xee\xbe\xa6' $'\xee\xbc\x8b')
  # djb2: a plain char sum maps private and private2 to one bucket ('2' is 50).
  ACCOUNT_HASH=5381
  for (( i=0; i<${#ACCOUNT}; i++ )); do
    printf -v CH '%d' "'${ACCOUNT:i:1}"
    ACCOUNT_HASH=$(( (ACCOUNT_HASH * 33 + CH) % 2147483647 ))
  done
  ACCOUNT_IDX=$((ACCOUNT_HASH % ${#ACCOUNT_PALETTE[@]}))
  # One digit in the profile's statusline-style file pins its colour+icon slot.
  if [ -f "$CLAUDE_CONFIG_DIR/statusline-style" ]; then
    ACCOUNT_PIN=""
    read -r ACCOUNT_PIN < "$CLAUDE_CONFIG_DIR/statusline-style"
    [[ "$ACCOUNT_PIN" =~ ^[0-9]$ ]] && ACCOUNT_IDX=$ACCOUNT_PIN
  fi
  ACCOUNT_COLOR=${ACCOUNT_PALETTE[$ACCOUNT_IDX]}
  ACCOUNT_ICON=${ACCOUNT_ICONS[$ACCOUNT_IDX]}
fi

fmt_tokens() {
  local t=$1
  if [ "$t" -ge 1000000 ]; then
    local m=$((t / 100000))
    echo "$((m / 10)).$((m % 10))M"
  elif [ "$t" -ge 1000 ]; then
    echo "$((t / 1000))k"
  else
    echo "${t}"
  fi
}

IN_FMT=$(fmt_tokens "$INPUT_T")
OUT_FMT=$(fmt_tokens "$OUTPUT_T")

# Countdown to a reset in its two largest units (1d7h, 4h5m, 12m), unpadded and
# without a zero second unit (1h, not 1h0m). Truncated, so it never overstates
# the wait; the last minute shows as <1m.
fmt_countdown() {
  local remain=$1 big=0 small=0 bu="" su=""
  [ "$remain" -lt 0 ] && remain=0
  local d=$((remain / 86400)) h=$(( (remain % 86400) / 3600 )) m=$(( (remain % 3600) / 60 ))
  if [ "$d" -ge 1 ]; then big=$d bu=d small=$h su=h
  elif [ "$h" -ge 1 ]; then big=$h bu=h small=$m su=m
  elif [ "$m" -ge 1 ]; then big=$m bu=m
  else printf '<1m'; return
  fi
  printf '%d%s' "$big" "$bu"
  if [ "$small" -gt 0 ]; then printf '%d%s' "$small" "$su"; fi
}

MINS=$((DURATION_MS / 60000)); SECS=$(((DURATION_MS % 60000) / 1000))
COST_FMT=$(printf '$%.2f' "$COST")
TIME_FMT=$(printf '%3dm%02ds' "$MINS" "$SECS")

BRANCH=""
git rev-parse --git-dir > /dev/null 2>&1 && BRANCH=$(git branch --show-current 2>/dev/null)

ICON_BRANCH=$'\xee\x82\xa0'
ICON_FOLDER=$'\xef\x84\x95'
SEP=$'\xee\x82\xb0'

A_BG='234'; B_BG='236'; C_BG='234'

R='\033[0m'; BOLD='\033[1m'
DIM_FG='\033[38;5;240m'

fg() { printf '\033[38;5;%sm' "$1"; }
bg() { printf '\033[48;5;%sm' "$1"; }
fgrgb() { printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"; }

# 3-stop RGB gradient: c0 up to lo, c0->c1->c2 across [lo,hi], c2 from hi up
gradient() {
  local p=$1 lo=$2 hi=$3 r0=$4 g0=$5 b0=$6 r1=$7 g1=$8 b1=$9 r2=${10} g2=${11} b2=${12}
  local mid=$(( (lo + hi) / 2 ))
  if [ "$p" -le "$lo" ]; then echo "$r0 $g0 $b0"; return; fi
  if [ "$p" -ge "$hi" ]; then echo "$r2 $g2 $b2"; return; fi
  if [ "$p" -le "$mid" ]; then
    local t=$(( (p - lo) * 100 / (mid - lo) ))
    echo "$(( r0 + (r1 - r0) * t / 100 )) $(( g0 + (g1 - g0) * t / 100 )) $(( b0 + (b1 - b0) * t / 100 ))"
  else
    local t=$(( (p - mid) * 100 / (hi - mid) ))
    echo "$(( r1 + (r2 - r1) * t / 100 )) $(( g1 + (g2 - g1) * t / 100 )) $(( b1 + (b2 - b1) * t / 100 ))"
  fi
}

GREEN=(175 215 0); YELLOW=(255 204 0); RED=(220 60 60); GRAY=(138 138 138)

# green -> yellow -> red as context fills up; yellow starts at 15%, full red at 30%+
CTX_RGB=($(gradient "$PCT" 15 30 "${GREEN[@]}" "${YELLOW[@]}" "${RED[@]}"))

DIR_SHORT="${DIR##*/}"

# build bar
FILLED=$((PCT * 10 / 100)); EMPTY=$((10 - FILLED))
[ "$FILLED" -gt 10 ] && FILLED=10 && EMPTY=0
BAR=""
for ((i=0;i<FILLED;i++)); do BAR+="$(fgrgb "${CTX_RGB[@]}")▰"; done
for ((i=0;i<EMPTY;i++)); do BAR+="${DIM_FG}▱"; done

# line 1: MODEL > BRANCH > FOLDER DIR > 5h:XX%
printf "${BOLD}$(fg 245)$(bg $A_BG) ${MODEL} ${R}"
CUR_BG=$A_BG
NEXT_BG=$B_BG
printf "$(fg $CUR_BG)$(bg $NEXT_BG)${SEP}${R}"
CUR_BG=$NEXT_BG
if [ -n "$BRANCH" ]; then
  printf "$(fg 252)$(bg $CUR_BG) ${ICON_BRANCH} ${BRANCH} ${R}"
  NEXT_BG=$A_BG
  printf "$(fg $CUR_BG)$(bg $NEXT_BG)${SEP}${R}"
  CUR_BG=$NEXT_BG
fi
printf "$(fg 245)$(bg $CUR_BG) ${ICON_FOLDER}  ${DIR_SHORT} ${R}"

# gray -> yellow -> red as a rate limit fills up; yellow starts at 75%, full red at 90%+
[ -n "$RATE_5H" ] && RATE_5H_RGB=($(gradient "$(printf '%.0f' "$RATE_5H")" 75 90 "${GRAY[@]}" "${YELLOW[@]}" "${RED[@]}"))
[ -n "$WEEK" ] && WEEK_RGB=($(gradient "$(printf '%.0f' "$WEEK")" 75 90 "${GRAY[@]}" "${YELLOW[@]}" "${RED[@]}"))

NOW=$(date +%s)
CD_5H=""
[ -n "$RESETS_5H" ] && CD_5H="$(fmt_countdown $((RESETS_5H - NOW)))"
CD_7D=""
[ -n "$RESETS_7D" ] && CD_7D="$(fmt_countdown $((RESETS_7D - NOW)))"

# 5h / 7d share one box; countdown-to-reset stands in for the label, no "5h"/"7d" prefix
RATE_PARTS=()
[ -n "$RATE_5H" ] && RATE_PARTS+=("$(fgrgb "${RATE_5H_RGB[@]}")${CD_5H}:$(printf '%.0f' "$RATE_5H")%%")
[ -n "$WEEK" ] && RATE_PARTS+=("$(fgrgb "${WEEK_RGB[@]}")${CD_7D}:$(printf '%.0f' "$WEEK")%%")
RATE_BLOCK=""
for i in "${!RATE_PARTS[@]}"; do
  [ "$i" -gt 0 ] && RATE_BLOCK+=" "
  RATE_BLOCK+="${RATE_PARTS[$i]}"
done

TAIL_IDS=()
[ -n "$RATE_BLOCK" ] && TAIL_IDS+=("rates")
[ -n "$ACCOUNT" ] && TAIL_IDS+=("account")

# rates and account share one flat background (no alternation between them)
if [ ${#TAIL_IDS[@]} -gt 0 ]; then
  TAIL_BG=$B_BG
  [ "$CUR_BG" = "$B_BG" ] && TAIL_BG=$A_BG
  printf "$(fg $CUR_BG)$(bg $TAIL_BG)${SEP}${R}"
  CUR_BG=$TAIL_BG
  for id in "${TAIL_IDS[@]}"; do
    case "$id" in
      rates) printf "$(bg $CUR_BG) ${RATE_BLOCK}${R}" ;;
      account) printf "$(bg $CUR_BG)$(fgrgb 127 132 156)${EMAIL:+ ${EMAIL}}$(fg $ACCOUNT_COLOR) ${ACCOUNT_ICON}  ${ACCOUNT} ${R}" ;;
    esac
  done
fi
printf "$(fg $CUR_BG)${SEP}${R}"
echo ""

# line 2: EFFORT > COST > TIME BAR PCT% > t:IN/OUT
printf "${BOLD}$(fg 245)$(bg $A_BG) ${EFFORT} ${R}"
printf "$(fg $A_BG)$(bg $B_BG)${SEP}${R}"
printf "$(fg 252)$(bg $B_BG) ${COST_FMT} ${R}"
printf "$(fg $B_BG)$(bg $C_BG)${SEP}${R}"
printf "$(fg 245)$(bg $C_BG) ${TIME_FMT}  ${BAR}${R}$(bg $C_BG)  $(fgrgb "${CTX_RGB[@]}")${PCT}%% ${R}"
printf "$(fg $C_BG)${SEP}${R}"
printf " $(fg 245)t:${IN_FMT}/${OUT_FMT}"
echo ""
