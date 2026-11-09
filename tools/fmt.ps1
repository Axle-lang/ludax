# fmt.ps1 — formats ludax's own sources and never the vendored platform library.
#
# A bare `axle fmt` walks every `.axle` file under the current directory, `vendor/smalt` included: it dirties the
# pinned submodule and rewrites `vendor/smalt/src/render/glyphs.axle` into a fraction of its size. This script
# points the formatter at the directories this repository owns only.
#
# Usage:  tools\fmt.ps1            format in place
#         tools\fmt.ps1 --check    list the files that would change, exit non-zero if any
#         tools\fmt.ps1 --diff     print what would change

Set-Location (Join-Path $PSScriptRoot "..")
axle fmt @args src tests examples
exit $LASTEXITCODE
