#!/usr/bin/env bash
# CI gate: Verdict invariants are frozen. A refactor that weakens
# validate() fails `assertion_freeze_test.zig`.
set -euo pipefail
cd "$(dirname "$0")/.."
exec zig build test --summary all
