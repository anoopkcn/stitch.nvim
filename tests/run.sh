#!/bin/sh
# Run every *_spec.lua headlessly; any failing check exits non-zero.
set -e
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for spec in "$dir"/*_spec.lua; do
  echo "== $(basename "$spec")"
  nvim --headless -u NONE -l "$spec"
done
echo "== all specs passed"
