#!/usr/bin/env bash
# fmt.sh — formats ludax's own sources and never the vendored platform library.
#
# A bare `axle fmt` walks every `.axle` file under the current directory, `vendor/smalt` included. smalt is a
# pinned submodule: reformatting it dirties the submodule, and the compiler's formatter does not parse all of it
# (it stops on `drop` in the wayland files and rewrites `src/render/glyphs.axle` into a fraction of its size). So
# the formatter is only ever pointed at the directories this repository owns.
#
# Usage:  tools/fmt.sh            format in place
#         tools/fmt.sh --check    list the files that would change, exit non-zero if any
#         tools/fmt.sh --diff     print what would change

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 2

exec axle fmt "$@" src tests examples games
