#!/usr/bin/env bash
# CI gate: enforce the per-run witness cardinality cap.
# The Zig-side `witness_cardinality_test` is the source of truth;
# this script runs the full test suite so the cap is checked as
# part of the release gate.
set -euo pipefail
cd "$(dirname "$0")/.."
exec zig build test --summary all
