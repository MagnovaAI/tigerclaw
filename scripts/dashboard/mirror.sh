#!/bin/zsh
# Read-only mirror of another tmux pane. Polls the target pane's
# captured contents twice a second, repaints only when content
# actually changed (so an idle target produces no terminal noise).
# Cursor-home + erase-EOL/below sequencing avoids the flicker that
# `clear` induces.
#
# Usage: mirror.sh <target> <label> [color]
#   target: tmux pane id (e.g. tigerdbg:tui)
#   label:  short banner text shown above the mirror
#   color:  cyan|yellow|green|<other> (default yellow)
#
# Cannot accept input — use tmux send-keys against the target, or
# join the real pane into the dashboard session via join-pane. See
# dashboard.sh for the recommended layout.

target=$1
label=$2
color_name=${3:-yellow}

case $color_name in
  cyan)   COLOR=$'\e[1;36m' ;;
  yellow) COLOR=$'\e[1;33m' ;;
  green)  COLOR=$'\e[1;32m' ;;
  *)      COLOR=$'\e[1m' ;;
esac
RESET=$'\e[0m'
HOME_CURSOR=$'\033[H'
ERASE_EOL=$'\033[K'
ERASE_DOWN=$'\033[J'
HIDE_CURSOR=$'\033[?25l'
SHOW_CURSOR=$'\033[?25h'

print -n -- "$HIDE_CURSOR"
trap 'print -n -- "$SHOW_CURSOR"' EXIT INT TERM

last=""
while :; do
  current=$(tmux capture-pane -t "$target" -p 2>/dev/null | tail -28)
  if [[ "$current" != "$last" ]]; then
    buf="$HOME_CURSOR${COLOR}=== ${label} ===${RESET}${ERASE_EOL}"$'\n'
    while IFS= read -r line; do
      buf+="${line}${ERASE_EOL}"$'\n'
    done <<< "$current"
    buf+="$ERASE_DOWN"
    print -n -- "$buf"
    last="$current"
  fi
  sleep 0.5
done
