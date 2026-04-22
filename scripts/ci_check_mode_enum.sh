#!/usr/bin/env bash
# CI gate: the Mode enum in settings.schema is the authoritative
# list of session modes. Changing its variants without migration
# breaks bench/replay/eval; this script grep-guards the set and
# fails if the known names are not present.
set -euo pipefail
cd "$(dirname "$0")/.."

missing=0
for name in run bench replay eval; do
  if ! grep -q "    ${name}," src/settings/schema.zig; then
    echo "ci_check_mode_enum: expected variant '${name}' missing from Mode"
    missing=1
  fi
done
exit "${missing}"
