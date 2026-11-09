#!/usr/bin/env bash
# suites.sh — fails when a test suite is declared but never run.
#
# A `pub class <Area>Suite` that nothing calls is silent: it compiles, and its checks simply never count. Every
# suite must be called as `<Name>::run(c)` from the `main.axle` of its test project (`tests/src` for the engine,
# `games/blockland/tests/src` for the game) or from another suite that groups it.
#
# Usage:  tools/suites.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
missing=0
for dir in "$root/tests/src" "$root/games"/*/tests/src; do
    [ -d "$dir" ] || continue
    for name in $(grep -ho 'pub class [A-Za-z0-9]*Suite' "$dir"/*.axle | awk '{print $3}'); do
        if ! grep -q "${name}::run(c)" "$dir"/*.axle; then
            echo "suite never run: $name ($dir)" >&2
            missing=$((missing + 1))
        fi
    done
done

if [ "$missing" -ne 0 ]; then
    echo "suites: $missing never run" >&2
    exit 1
fi
echo "suites: all run"
