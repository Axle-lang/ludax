#!/usr/bin/env bash
# examples.sh — builds every example and runs the ones that check themselves.
#
# The headless examples print what they verified and exit with the number of failures, so a green run here
# means each layer still does what its example demonstrates. `lumen` runs its `--selftest`; the two small games
# (bastion, stardrift) open a window, so they are only built.
#
# Usage:  tools/examples.sh [name ...]     (no name: all)

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root/examples" || exit 2

failed=0
names=("$@")
if [ ${#names[@]} -eq 0 ]; then
    names=(assetdb chimes frontier kinetic lumen orrery prism texlab voxelwalk wayfarer bastion stardrift)
fi

for name in "${names[@]}"; do
    dir="$root/examples/$name"
    if [ ! -d "$dir" ]; then
        echo "no such example: $name" >&2
        failed=$((failed + 1))
        continue
    fi
    echo "== $name"
    # A scratch output path keeps a running copy of the program from locking the executable.
    exe="${TMPDIR:-/tmp}/ludax-example-$name.exe"
    if ! (cd "$dir" && axle build -O 3 -o "$exe" >/dev/null 2>&1); then
        echo "   BUILD FAILED" >&2
        failed=$((failed + 1))
        continue
    fi
    case "$name" in
        bastion | stardrift)
            echo "   built (opens a window; not run)"
            ;;
        lumen)
            if (cd "$dir" && "$exe" --selftest >/dev/null 2>&1); then
                echo "   selftest passed"
            else
                echo "   SELFTEST FAILED" >&2
                failed=$((failed + 1))
            fi
            ;;
        *)
            # Run in a scratch folder so the pictures and files an example writes do not litter the tree.
            scratch="$(mktemp -d)"
            if (cd "$scratch" && "$exe" >"$scratch/out.txt" 2>&1); then
                echo "   $(tail -n 1 "$scratch/out.txt")"
            else
                echo "   FAILED:" >&2
                tail -n 5 "$scratch/out.txt" >&2
                failed=$((failed + 1))
            fi
            rm -rf "$scratch"
            ;;
    esac
    rm -f "$exe"
done

if [ "$failed" -ne 0 ]; then
    echo "examples: $failed failed" >&2
    exit 1
fi
echo "examples: all passed"
