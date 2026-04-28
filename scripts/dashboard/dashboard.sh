#!/bin/zsh
# Build a 4-pane tmux debug dashboard for tigerclaw.
#
# Layout (tiled):
#
#   ┌─ procmon (tmux + procs + gateway tail) ─┬─ TIGER TUI (real, interactive) ─┐
#   ├─ tail -F /tmp/tigerdbg-*.log ───────────┼─ GATEWAY (real, interactive) ───┤
#
# Both right-column panes are real tigerclaw processes — type into
# them as if they were ordinary terminals. The left column is
# observability only.
#
# Usage:
#   ./scripts/dashboard/dashboard.sh             # build session named "dash"
#   ./scripts/dashboard/dashboard.sh other_name  # custom session name
#   tmux attach -t dash                          # attach when ready
#
# Detach with Ctrl-b d. Switch panes with Ctrl-b o (or arrows).
# Kill session: tmux kill-session -t dash.

set -e

SESSION=${1:-dash}
ROOT=${TIGERCLAW_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
SCRIPTS="$ROOT/scripts/dashboard"
TUI_LOG=${TUI_LOG:-/tmp/tigerdbg-tui.log}
GW_LOG=${GW_LOG:-/tmp/tigerdbg-gateway.log}

if [[ ! -x "$ROOT/zig-out/bin/tigerclaw" ]]; then
  echo "error: $ROOT/zig-out/bin/tigerclaw not found — run 'zig build' first" >&2
  exit 1
fi

# Reset prior session and any stray tigerclaw processes from a
# previous dashboard run. The wrapper shells around the binaries
# `sleep 60` after exit so the pane stays open long enough for the
# operator to read a crash; pkill them too.
tmux kill-session -t "$SESSION" 2>/dev/null || true
pkill -f "$ROOT/zig-out/bin/tigerclaw" 2>/dev/null || true
pkill -f "sleep 60" 2>/dev/null || true
sleep 1

: > "$TUI_LOG"
: > "$GW_LOG"

# Pane 0: procmon (top-left)
tmux new-session -d -s "$SESSION" -x 240 -y 64 -n dash \
  "GATEWAY_LOG='$HOME/.tigerclaw/instances/default/logs/server.log' $SCRIPTS/procmon.sh"

# Pane 1: TUI (top-right) — real interactive tigerclaw
tmux split-window -h -t "$SESSION:dash.0" -c "$ROOT" \
  "./zig-out/bin/tigerclaw 2>>$TUI_LOG; echo '=== TUI EXITED ===' >> $TUI_LOG; sleep 60"

# Pane 2: gateway (bottom-right) — real interactive gateway daemon
tmux split-window -v -t "$SESSION:dash.1" -c "$ROOT" \
  "./zig-out/bin/tigerclaw gateway 2>&1 | tee $GW_LOG; echo '=== GW EXITED ===' >> $GW_LOG; sleep 60"

# Pane 3: combined log tail (bottom-left)
tmux split-window -v -t "$SESSION:dash.0" \
  "tail -F $TUI_LOG $GW_LOG 2>&1"

tmux select-layout -t "$SESSION:dash" tiled

cat <<EOF
dashboard ready. Attach with:
  tmux attach -t $SESSION

panes:
  0: procmon (sessions, tigerclaw procs, gateway tail)
  1: TUI (interactive)
  2: gateway (interactive)
  3: tail -F $TUI_LOG $GW_LOG

logs:
  TUI:     $TUI_LOG
  gateway: $GW_LOG
EOF
