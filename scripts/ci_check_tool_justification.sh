#!/usr/bin/env bash
# CI gate: every built-in tool must declare a Category (1/2/3/4) and
# names must be unique. Runs the Zig-side lint test suite; no
# extra duplication of the rules in shell.
set -euo pipefail
cd "$(dirname "$0")/.."
exec zig build test --summary all
