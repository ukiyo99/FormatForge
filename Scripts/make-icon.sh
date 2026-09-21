#!/bin/bash
# Build Resources/AppIcon.icns from Resources/AppIcon-source.png.
#
# The supplied artwork is a 1254×1254 PNG whose visible content occupies an
# 876×875 region centred with ~188 px of transparent margin. macOS expects icon
# artwork to fill its canvas, so we crop to the content bounds first, then
# render every size the system asks for.
#
# Usage: ./Scripts/make-icon.sh [source.png]

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SOURCE="${1:-$ROOT/Resources/AppIcon-source.png}"
OUT="$ROOT/Resources/AppIcon.icns"
WORK="${TMPDIR:-/tmp}/formatforge-icon"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; BLUE=$'\033[0;34m'; RESET=$'\033[0m'
info() { echo "${BLUE}▸${RESET} $*"; }
ok()   { echo "${GREEN}✓${RESET} $*"; }
fail() { echo "${RED}✗${RESET} $*" >&2; exit 1; }

[[ -f "$SOURCE" ]] || fail "Icon source not found: $SOURCE"
command -v sips >/dev/null || fail "sips is required (it ships with macOS)"

rm -rf "$WORK"; mkdir -p "$WORK/AppIcon.iconset"

info "Cropping to the content bounds…"
# `sips --cropToHeightWidth` crops centred, which is exactly right here: the
# artwork is centred with equal margins on all four sides.
read -r W H <<< "$(sips -g pixelWidth -g pixelHeight "$SOURCE" \
    | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w, h}')"
info "Source size ${W}×${H}"

# Determine the visible square by measuring alpha bounds via a tiny Swift tool.
CROP="$WORK/crop.txt"
if [[ ! -x "$WORK/bounds" ]]; then
    cat > "$WORK/bounds.swift" <<'SWIFT'
import Foundation
import CoreGraphics
import ImageIO

// Print the alpha bounding box of an image: "x y width height".
@main struct Bounds {
    static func main() {
        let path = CommandLine.arguments[1]
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { exit(1) }
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w where buf[(y * w + x) * 4 + 3] >= 8 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { print("0 0 \(w) \(h)"); return }
        print("\(minX) \(minY) \(maxX - minX + 1) \(maxY - minY + 1)")
    }
}
SWIFT
    SDK="${FORMATFORGE_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
    swiftc -sdk "$SDK" -module-cache-path "$WORK/mod" -parse-as-library \
           -o "$WORK/bounds" "$WORK/bounds.swift" 2>/dev/null \
        || fail "Could not compile the bounds-detection tool"
fi

read -r BX BY BW BH <<< "$("$WORK/bounds" "$SOURCE")"
info "Content bounds ${BW}×${BH} @ (${BX},${BY})"

# Pad to a square if the artwork is not exactly square.
SIDE=$(( BW > BH ? BW : BH ))
info "Cropping to a square ${SIDE}×${SIDE}"

# `sips` can only crop centred, so verify the artwork really is centred before
# relying on that; otherwise fall back to the full canvas.
LEFT=$BX; RIGHT=$(( W - BX - BW )); TOP=$BY; BOTTOM=$(( H - BY - BH ))
MAXMARGIN=$(( LEFT > RIGHT ? LEFT : RIGHT ))
[[ $TOP -gt $MAXMARGIN ]] && MAXMARGIN=$TOP
[[ $BOTTOM -gt $MAXMARGIN ]] && MAXMARGIN=$BOTTOM
if [[ $(( MAXMARGIN - (LEFT < RIGHT ? LEFT : RIGHT) )) -gt 6 ]]; then
    echo "  ! Content is not centred; using the full canvas to avoid an off-centre crop" >&2
    SIDE=$W
fi

cp "$SOURCE" "$WORK/square.png"
sips --cropToHeightWidth "$SIDE" "$SIDE" "$WORK/square.png" >/dev/null 2>&1 \
    || fail "Crop failed"
sips -g pixelWidth -g pixelHeight "$WORK/square.png" | tail -2 | sed 's/^/  /'

info "Generating every size…"
# Sizes macOS requests. The @2x variants matter for Retina displays.
for spec in "16:16" "32:32:16" "64:32:32" "128:128" "256:128:128" \
            "512:256:256" "1024:512:512" "1024:512:512"; do
    IFS=':' read -r px logical scale <<< "$spec"
    if [[ -n "${scale:-}" ]]; then
        name="icon_${logical}x${logical}@2x.png"
    else
        name="icon_${px}x${px}.png"
    fi
    sips -z "$px" "$px" "$WORK/square.png" --out "$WORK/AppIcon.iconset/$name" >/dev/null 2>&1
done

# Ensure the exact names iconutil expects.
for n in 16 32 128 256 512; do
    [[ -f "$WORK/AppIcon.iconset/icon_${n}x${n}.png" ]] || \
        sips -z $n $n "$WORK/square.png" --out "$WORK/AppIcon.iconset/icon_${n}x${n}.png" >/dev/null 2>&1
    [[ -f "$WORK/AppIcon.iconset/icon_${n}x${n}@2x.png" ]] || \
        sips -z $((n*2)) $((n*2)) "$WORK/square.png" \
             --out "$WORK/AppIcon.iconset/icon_${n}x${n}@2x.png" >/dev/null 2>&1
done

ls "$WORK/AppIcon.iconset" | sort | sed 's/^/  /'

iconutil -c icns "$WORK/AppIcon.iconset" -o "$OUT" || fail "iconutil failed"
ok "Wrote ${OUT} ($(du -h "$OUT" | cut -f1))"
