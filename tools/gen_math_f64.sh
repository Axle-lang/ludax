#!/usr/bin/env bash
# gen_math_f64.sh — derives the f64 maths files (src/core/math/d*.axle) from their f32 originals.
#
# Axle has no generics over number types, and the engine needs the same vectors, matrices, quaternions and
# shapes in f64 for world positions. Rather than keep two copies in step by hand, the f32 files are the source
# and this script rewrites them: f32 -> f64, each type T -> DT, each module m -> dm, scalar/trig functions to
# their `D` twins, file-private constants and helpers prefixed so that names stay unique across the package.
# The output is committed; run the script after editing an original and commit both.
#
# Usage:  tools/gen_math_f64.sh

set -euo pipefail
cd "$(dirname "$0")/.."
DIR=src/core/math
MODULES="vec2 vec3 vec4 mat3 mat4 quat transform geom intersect"
TYPES="Vec2|Vec3|Vec4|Mat3|Mat4|Quat|Transform|Aabb|Sphere|Ray|Plane|RayHit"
FUNCS="min|max|abs|sign|clamp|saturate|lerp|approxEqWithin|sin|cos|tan|acos|asin|atan2"
MODS_RE=$(echo "$MODULES" | tr ' ' '|')

for m in $MODULES; do
    out="$DIR/d$m.axle"
    perl -e '
        my ($types, $funcs, $mods) = @ARGV;
        shift; shift; shift;
        my @lines = <STDIN>;
        my %rename;
        for (@lines) {
            $rename{$1} = "D_$1" if /^const (\w+)/;
            $rename{$1} = $1 . "D" if /^(?:pub )?fn (\w+)/;
            $rename{$1} = "D$1" if /^struct (\w+)/;
        }
        my $first = 1;
        for (@lines) {
            if ($first) {
                s/^\/\/ (\w+) — /\/\/ d$1 — /;
                s/\bf32\b/f64/g;
                $first = 0;
                print;
                print "// Generated from $ARGV[0].axle by tools/gen_math_f64.sh: edit the original, not this file.\n";
                next;
            }
            if (/^use crate::core::math::(scalar|trig)::/) {
                s/\b($funcs)\b/$1D/g;
                s/\bHUGE\b/HUGE_D/g;
            } else {
                s/(?<!fn )(?<![.\w])($funcs)(?=\()/$1D/g;
                s/\bHUGE\b/HUGE_D/g;
            }
            s/\bf32\b/f64/g;
            s/\b($types)\b/D$1/g;
            s/math::($mods)::/math::d$1::/g;
            for my $name (keys %rename) { s/\b$name\b/$rename{$name}/g; }
            print;
        }
    ' "$TYPES" "$FUNCS" "$MODS_RE" "$m" <"$DIR/$m.axle" >"$out"
done
