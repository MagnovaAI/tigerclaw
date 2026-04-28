#!/bin/zsh
# Live tmux-pane process monitor for tigerclaw debug sessions.
#
# Renders three sections — tmux session list, tigerclaw process
# stats, and the tail of the gateway server log — without the
# flicker that `clear; print` produces. Each frame writes
# cursor-home + the new content + erase-below in one syscall, and
# every line carries an erase-to-EOL escape so longer prior content
# can't bleed through.
#
# Pair with mirror.sh (read-only mirror of another tmux pane) when
# building a debug dashboard. See dashboard.sh for the wiring.

HOME_CURSOR=$'\033[H'
ERASE_EOL=$'\033[K'
ERASE_DOWN=$'\033[J'
HIDE_CURSOR=$'\033[?25l'
SHOW_CURSOR=$'\033[?25h'
CYAN=$'\e[1;36m'
RESET=$'\e[0m'

GATEWAY_LOG=${GATEWAY_LOG:-$HOME/.tigerclaw/instances/default/logs/server.log}

print -n -- "$HIDE_CURSOR"
trap 'print -n -- "$SHOW_CURSOR"' EXIT INT TERM

while :; do
  buf="$HOME_CURSOR"
  buf+="${CYAN}=== tmux sessions ===${RESET}${ERASE_EOL}"$'\n'
  while IFS= read -r line; do
    buf+="${line}${ERASE_EOL}"$'\n'
  done < <(tmux ls 2>/dev/null)
  buf+="${ERASE_EOL}"$'\n'
  buf+="${CYAN}=== tigerclaw processes ===${RESET}${ERASE_EOL}"$'\n'
  while IFS= read -r line; do
    buf+="${line}${ERASE_EOL}"$'\n'
  done < <(ps aux | grep '[z]ig-out/bin/tigerclaw' | awk '{printf "%-7s %5s%%  %7.1fMB  %s %s %s\n", $2, $3, $6/1024, $11, $12, $13}')
  buf+="${ERASE_EOL}"$'\n'
  buf+="${CYAN}=== gateway tail ===${RESET}${ERASE_EOL}"$'\n'
  while IFS= read -r line; do
    buf+="${line}${ERASE_EOL}"$'\n'
  done < <(tail -n 6 "$GATEWAY_LOG" 2>/dev/null)
  buf+="$ERASE_DOWN"
  print -n -- "$buf"
  sleep 1
done
