#!/usr/bin/env bash
set -euo pipefail

# render-icon.sh
#
# Regenerates the app icon from its master artwork, docs/brand/icon.svg (spec-tech-batch-7 §E):
#
#   - every macOS AppIcon PNG (16-512 pt at @1x and @2x) into
#     Salvage/Assets.xcassets/AppIcon.appiconset/ (its Contents.json is committed, not generated);
#   - docs/brand/icon-1024.png, the 1024px copy for review.
#
# Uses only system tools: the Swift toolchain that ships with Xcode, AppKit's built-in SVG
# renderer and CoreGraphics (scripts/render-icon.swift). No downloads, no fonts, no network.
# Deterministic: an unchanged SVG re-renders to byte-identical PNGs, so after editing the SVG,
# run this and commit whatever changed.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
svg="$root/docs/brand/icon.svg"
iconset="$root/Salvage/Assets.xcassets/AppIcon.appiconset"

[ -f "$svg" ] || { echo "render-icon.sh: $svg not found" >&2; exit 1; }
[ -d "$iconset" ] || { echo "render-icon.sh: $iconset not found" >&2; exit 1; }

swift "$root/scripts/render-icon.swift" "$svg" "$iconset"
cp "$iconset/icon_512x512@2x.png" "$root/docs/brand/icon-1024.png"
echo "wrote docs/brand/icon-1024.png"
