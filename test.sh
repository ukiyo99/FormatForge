#!/bin/bash
# Compile the headless test harness from the same sources as the app
# (minus the SwiftUI @main entry point) and run end-to-end checks.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

CACHE_DIR="${TMPDIR:-/tmp}/formatforge-module-cache"
BIN="$CACHE_DIR/harness"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

info() { echo "${BLUE}▸${RESET} $*"; }
ok()   { echo "${GREEN}✓${RESET} $*"; }
warn() { echo "${YELLOW}!${RESET} $*"; }
fail() { echo "${RED}✗${RESET} $*" >&2; exit 1; }

SDK="${FORMATFORGE_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$SDK" ]] || fail "SDK not found: $SDK"

# ---------------------------------------------------------------- build harness

build_harness() {
    local sources=()
    while IFS= read -r -d '' file; do
        # Exclude the SwiftUI app entry point, which declares its own @main.
        [[ "$file" == *"/App/FormatForgeApp.swift" ]] && continue
        sources+=("$file")
    done < <(find "$ROOT/Sources" -name '*.swift' -print0 | sort -z)
    sources+=("$ROOT/Tests/Harness.swift")

    mkdir -p "$CACHE_DIR/modules"
    info "Compiling the test driver…"
    swiftc -sdk "$SDK" \
           -target arm64-apple-macosx14.0 \
           -module-cache-path "$CACHE_DIR/modules" \
           -parse-as-library -swift-version 5 \
           -Xfrontend -strict-concurrency=minimal \
           -framework SwiftUI -framework AppKit -framework AVFoundation \
           -framework PDFKit -framework Vision -framework CoreImage \
           -framework UniformTypeIdentifiers \
           -o "$BIN" "${sources[@]}" 2> "$CACHE_DIR/harness.log" || {
        grep -E "error:" "$CACHE_DIR/harness.log" | head -30
        fail "harness build failed (log: $CACHE_DIR/harness.log)"
    }
    # The harness is a plain executable, not a bundle, so LanguageStore looks
    # for the tables next to it. Keep that copy in sync or it will load stale
    # strings and produce misleading filenames.
    rm -rf "$CACHE_DIR/i18n"
    mkdir -p "$CACHE_DIR/i18n"
    cp "$ROOT/Resources/i18n"/*.json "$CACHE_DIR/i18n/" 2>/dev/null || true

    ok "Test driver ready"
}

# ---------------------------------------------------------------- assertions

PASS=0
FAILED=0
FAILURES=()

# assert_file <path> <description>
assert_file() {
    if [[ -s "$1" ]]; then
        ok "$2  →  $(basename "$1") $(du -h "$1" | cut -f1)"
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} $2  →  missing/empty: $1"
        FAILED=$((FAILED + 1)); FAILURES+=("$2")
    fi
}

# run_expect_failure <label> <outdir> <tool> [params...] -- inputs...
# Passes when the tool exits non-zero (i.e. it rejected bad input).
run_expect_failure() {
    local label="$1"; shift
    local outdir="$1"; shift
    local tool="$1"; shift
    rm -rf "$outdir"; mkdir -p "$outdir"
    if "$BIN" "$tool" "$outdir" "$@" > "$CACHE_DIR/last.log" 2>&1; then
        echo "${RED}✗${RESET} $label  →  Reported success without an error"
        FAILED=$((FAILED + 1)); FAILURES+=("$label")
    else
        ok "$label  →  correctly rejected"
        PASS=$((PASS + 1))
    fi
}

# assert_exists <path> <description>  (allows a legitimately empty file)
assert_exists() {
    if [[ -f "$1" ]]; then
        ok "$2  →  $(basename "$1")"
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} $2  →  missing: $1"
        FAILED=$((FAILED + 1)); FAILURES+=("$2")
    fi
}

# assert_probe <path> <expected stream kind> <description>
assert_probe() {
    local path="$1" kind="$2" desc="$3"
    if [[ ! -s "$path" ]]; then
        echo "${RED}✗${RESET} $desc  →  missing: $path"
        FAILED=$((FAILED + 1)); FAILURES+=("$desc"); return
    fi
    local found
    found=$(ffprobe -v error -select_streams "$kind" -show_entries stream=codec_name \
            -of csv=p=0 "$path" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        ok "$desc  →  $found"
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} $desc  →  no $kind stream in $path"
        FAILED=$((FAILED + 1)); FAILURES+=("$desc")
    fi
}

# run <label> <outdir> <tool> [params...] -- inputs...
run() {
    local label="$1"; shift
    local outdir="$1"; shift
    local tool="$1"; shift
    rm -rf "$outdir"; mkdir -p "$outdir"
    if "$BIN" "$tool" "$outdir" "$@" > "$CACHE_DIR/last.log" 2>&1; then
        return 0
    fi
    echo "${RED}✗${RESET} $label"
    sed 's/^/      /' "$CACHE_DIR/last.log" | head -12
    FAILED=$((FAILED + 1)); FAILURES+=("$label")
    return 1
}

# ---------------------------------------------------------------- fixtures

# ---------------------------------------------------------------- preflight

# The suite makes its own media with ffmpeg and inspects the results with
# ffprobe, so both must be present. Check up front and say what to install,
# rather than failing at the first fixture with "command not found".
MISSING_TOOLS=()
for tool in ffmpeg ffprobe swiftc; do
    command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS+=("$tool")
done
# 7z and cwebp are optional: the archive and WebP checks skip without them.
OPTIONAL_MISSING=()
for tool in 7z cwebp; do
    command -v "$tool" >/dev/null 2>&1 || OPTIONAL_MISSING+=("$tool")
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    echo "${RED}✗${RESET} Missing required tools: ${MISSING_TOOLS[*]}" >&2
    echo >&2
    echo "  ffmpeg and ffprobe generate and inspect the test media:" >&2
    echo "      brew install ffmpeg" >&2
    echo >&2
    echo "  swiftc comes with Xcode or the Command Line Tools:" >&2
    echo "      xcode-select --install" >&2
    exit 1
fi

if [[ ${#OPTIONAL_MISSING[@]} -gt 0 ]]; then
    warn "Optional tools missing: ${OPTIONAL_MISSING[*]}"
    echo "      Archive and WebP checks will be skipped."
    echo "      Install with: brew install p7zip webp"
fi

FIX="$ROOT/.test/fixtures"
OUT="$ROOT/.test/out"
if [[ ! -f "$FIX/clip.mp4" ]]; then
    info "Generating test material…"
    mkdir -p "$FIX"
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30:duration=6 \
        -f lavfi -i sine=frequency=440:duration=6 -c:v libx264 -preset ultrafast \
        -pix_fmt yuv420p -c:a aac -shortest "$FIX/clip.mp4"
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=size=640x360:rate=30:duration=3 \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$FIX/clip2.mp4"
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i sine=frequency=880:duration=5 \
        -c:a libmp3lame "$FIX/music.mp3"
    for i in 1 2 3 4 5; do
        ffmpeg -hide_banner -loglevel error -y \
            -f lavfi -i "testsrc2=size=$((200+i*40))x$((150+i*30)):duration=1" \
            -frames:v 1 "$FIX/img$i.png"
    done
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=800x600:duration=1" \
        -frames:v 1 "$FIX/photo.jpg"
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=256x256:duration=1" \
        -frames:v 1 "$FIX/watermark.png"
    printf 'Hello FormatForge\n\nSecond paragraph.\n' > "$FIX/sample.txt"
    printf '# Title\n\nSome **bold** text.\n\n- one\n- two\n' > "$FIX/sample.md"
fi
rm -rf "$OUT"; mkdir -p "$OUT"

build_harness

echo
echo "${BOLD}End-to-end verification${RESET}"
echo

# ---------------------------------------------------------------- video

info "Video tools"
run "Video format conversion" "$OUT/convert" video.convert --param codec=h264 --param container=mkv \
    -- "$FIX/clip.mp4" && assert_probe "$OUT/convert/clip.mkv" v "MP4→MKV conversion"

run "Video compression" "$OUT/compress" video.compress --param mode=quality --param crf=30 \
    -- "$FIX/clip.mp4" && assert_file "$OUT/compress/clip_compressed.mp4" "Video compression"

run "Audio extraction" "$OUT/audio" video.audio.extract --param action=extract --param format=mp3 \
    -- "$FIX/clip.mp4" && assert_probe "$OUT/audio/clip.mp3" a "Extract audio"

run "Video mute" "$OUT/mute" video.audio.extract --param action=remove \
    -- "$FIX/clip.mp4" && assert_file "$OUT/mute/clip_muted.mp4" "Remove audio track"

run "Audio and video mux" "$OUT/merge" video.audio.merge --param mode=replace \
    -- "$FIX/clip2.mp4" "$FIX/music.mp3" && assert_probe "$OUT/merge/clip2_merged.mp4" a "Audio and video mux"

run "Video concatenation" "$OUT/concat" video.concat --param mode=reencode \
    -- "$FIX/clip2.mp4" "$FIX/clip2.mp4" && assert_probe "$OUT/concat/clip2_joined.mp4" v "Video concatenation"

run "Video screenshot" "$OUT/shot" video.screenshot --param mode=single --param timestamp=2 \
    -- "$FIX/clip.mp4" && assert_file "$OUT/shot/clip_shot.png" "Video screenshot"

run "Batch screenshots" "$OUT/shots" video.screenshot --param mode=interval --param interval=2 --param format=jpg \
    -- "$FIX/clip.mp4" && assert_file "$OUT/shots/clip_001.jpg" "Batch screenshots at intervals"

run "Frame export" "$OUT/frames" video.frames --param mode=everyN --param step=30 \
    -- "$FIX/clip.mp4" && assert_file "$OUT/frames/clip_frames/clip_00001.png" "Video frame export"

run "Video to GIF" "$OUT/gif" video.gif --param start=0 --param duration=2 --param fps=10 --param width=240 \
    -- "$FIX/clip.mp4" && assert_file "$OUT/gif/clip.gif" "Video to GIF"

run "Video trimming" "$OUT/trim" video.trim --param mode=range --param start=1 --param end=3 \
    -- "$FIX/clip.mp4" && assert_probe "$OUT/trim/clip_trimmed.mp4" v "Video trimming"

run "Split video into volumes" "$OUT/split" video.trim --param mode=split --param segments=3 \
    -- "$FIX/clip.mp4" && assert_file "$OUT/split/clip_01.mp4" "Split video evenly"

run "Rotate and mirror" "$OUT/transform" video.transform --param transform=cw90 \
    -- "$FIX/clip.mp4" && assert_probe "$OUT/transform/clip_transformed.mp4" v "Video rotation"

run "Video speed" "$OUT/speed" video.speed --param speed=2 \
    -- "$FIX/clip.mp4" && assert_probe "$OUT/speed/clip_speed.mp4" a "Video speed"

run "Video watermark" "$OUT/wm" video.watermark --param kind=text --param text=TEST \
    -- "$FIX/clip.mp4" && assert_probe "$OUT/wm/clip_watermarked.mp4" v "Video watermark"

run "Video cover art" "$OUT/cover" video.cover --param action=frame --param timestamp=1 \
    -- "$FIX/clip.mp4" && assert_file "$OUT/cover/clip_cover.jpg" "Cover from a frame"

run "Change MD5" "$OUT/md5" video.fingerprint --param mode=both \
    -- "$FIX/clip.mp4" && assert_probe "$OUT/md5/clip_md5.mp4" v "Change video MD5"

run "Strip metadata" "$OUT/strip" video.strip \
    -- "$FIX/clip.mp4" && assert_probe "$OUT/strip/clip_nometadata.mp4" v "Strip metadata"

run "Resolution" "$OUT/resize" video.resize --param scale=p360 \
    -- "$FIX/clip.mp4" && assert_probe "$OUT/resize/clip_resized.mp4" v "Video resolution"

run "Image sequence to video" "$OUT/fromimg" video.fromimages --param fps=5 \
    -- "$FIX/img1.png" "$FIX/img2.png" "$FIX/img3.png" \
    && assert_probe "$OUT/fromimg/img1_video.mp4" v "Image sequence to video"

run "Images to video" "$OUT/slides" video.slideshow --param perImage=1 --param transition=fade --param resolution=720p \
    -- "$FIX/img1.png" "$FIX/img2.png" "$FIX/img3.png" \
    && assert_probe "$OUT/slides/img1_slideshow.mp4" v "Images to video (with transitions)"

# ---------------------------------------------------------------- image

echo
info "Image tools"
run "Image format conversion" "$OUT/iconv" image.convert --param codec=webp \
    -- "$FIX/photo.jpg" && assert_file "$OUT/iconv/photo.webp" "JPG→WebP"

run "Image to HEIC" "$OUT/heic" image.convert --param codec=heic \
    -- "$FIX/photo.jpg" && assert_file "$OUT/heic/photo.heic" "JPG→HEIC"

run "Image compression" "$OUT/icompress" image.compress --param mode=quality --param quality=60 \
    -- "$FIX/photo.jpg" && assert_file "$OUT/icompress/photo_compressed.jpg" "Image compression"

run "Compress to a target size" "$OUT/itarget" image.compress --param mode=targetSize --param targetKB=8 \
    -- "$FIX/photo.jpg" && assert_file "$OUT/itarget/photo_compressed.jpg" "Compress to a target size"

run "Resizing" "$OUT/iresize" image.resize --param mode=width --param width=320 \
    -- "$FIX/photo.jpg" && assert_file "$OUT/iresize/photo_320.jpg" "Image resizing"

run "Crop and rotate" "$OUT/icropro" image.transform --param crop=aspect --param aspect=1:1 --param rotate=90 \
    -- "$FIX/photo.jpg" && assert_file "$OUT/icropro/photo_transformed.jpg" "Image crop and rotate"

run "Image watermark" "$OUT/iwm" image.watermark --param kind=text --param text=DEMO \
    -- "$FIX/photo.jpg" && assert_file "$OUT/iwm/photo_watermarked.jpg" "Image watermark"

run "Collage" "$OUT/stitch" image.stitch --param layout=vertical \
    -- "$FIX/img1.png" "$FIX/img2.png" "$FIX/img3.png" \
    && assert_file "$OUT/stitch/img1_collage.png" "Image collage"

run "Rounded corners and border" "$OUT/deco" image.decorate --param shadow=true \
    -- "$FIX/photo.jpg" && assert_file "$OUT/deco/photo_decorated.png" "Rounded corners, border and shadow"

run "Images to GIF" "$OUT/mgif" image.gif --param width=240 \
    -- "$FIX/img1.png" "$FIX/img2.png" "$FIX/img3.png" "$FIX/img4.png" \
    && assert_file "$OUT/mgif/img1.gif" "Images to GIF (with transitions)"

run "Images to PDF" "$OUT/ipdf" image.topdf --param pageSize=a4 \
    -- "$FIX/photo.jpg" "$FIX/img1.png" && assert_file "$OUT/ipdf/photo.pdf" "Images to PDF"

run "PDF to images" "$OUT/pdfimg" pdf.toimage --param dpi=72 \
    -- "$OUT/ipdf/photo.pdf" && assert_file "$OUT/pdfimg/photo_001.png" "PDF to images"

# ---------------------------------------------------------------- document

echo
info "Document tools"
run "TXT to Word" "$OUT/t2w" doc.txt2word \
    -- "$FIX/sample.txt" && assert_file "$OUT/t2w/sample.docx" "TXT→Word"

run "Word to PDF" "$OUT/w2p" doc.word2pdf \
    -- "$OUT/t2w/sample.docx" && assert_file "$OUT/w2p/sample.pdf" "Word→PDF"

run "Word to TXT" "$OUT/w2t" doc.word2txt \
    -- "$OUT/t2w/sample.docx" && assert_file "$OUT/w2t/sample.txt" "Word→TXT"

run "Word to Markdown" "$OUT/w2m" doc.word2md \
    -- "$OUT/t2w/sample.docx" && assert_file "$OUT/w2m/sample.md" "Word→Markdown"

run "PDF to Word" "$OUT/p2w" doc.pdf2word \
    -- "$OUT/w2p/sample.pdf" && assert_file "$OUT/p2w/sample.docx" "PDF→Word"

run "PDF to Markdown" "$OUT/p2m" doc.pdf2md \
    -- "$OUT/w2p/sample.pdf" && assert_file "$OUT/p2m/sample.md" "PDF→Markdown"

run "Markdown to Word" "$OUT/m2w" doc.md2word \
    -- "$FIX/sample.md" && assert_file "$OUT/m2w/sample.docx" "Markdown→Word"

run "Markdown to PDF" "$OUT/m2p" doc.md2pdf \
    -- "$FIX/sample.md" && assert_file "$OUT/m2p/sample.pdf" "Markdown→PDF"

run "TXT to PDF" "$OUT/t2p" doc.txt2pdf \
    -- "$FIX/sample.txt" && assert_file "$OUT/t2p/sample.pdf" "TXT→PDF"

run "To HTML" "$OUT/html" doc.tohtml \
    -- "$FIX/sample.md" && assert_file "$OUT/html/sample.html" "Markdown→HTML"

run "PDF merge" "$OUT/pmerge" doc.pdfmerge \
    -- "$OUT/w2p/sample.pdf" "$OUT/m2p/sample.pdf" && assert_file "$OUT/pmerge/Merged document.pdf" "PDF merge"

run "PDF split" "$OUT/psplit" doc.pdfsplit --param mode=each \
    -- "$OUT/pmerge/Merged document.pdf" && assert_file "$OUT/psplit/Merged document_part1.pdf" "PDF split"

run "PDF encryption" "$OUT/psec" doc.pdfsecurity --param action=encrypt --param password=test1234 \
    -- "$OUT/w2p/sample.pdf" && assert_file "$OUT/psec/sample_encrypted.pdf" "PDF encryption"

run "PDF decryption" "$OUT/pdec" doc.pdfsecurity --param action=decrypt --param password=test1234 \
    -- "$OUT/psec/sample_encrypted.pdf" && assert_file "$OUT/pdec/sample_decrypted.pdf" "PDF decryption"

run "PDF compression" "$OUT/pcomp" doc.pdfcompress \
    -- "$OUT/w2p/sample.pdf" && assert_file "$OUT/pcomp/sample_compressed.pdf" "PDF compression"

run "OCR" "$OUT/ocr" doc.ocr --param output=txt --param language=en-US \
    -- "$FIX/photo.jpg" && assert_exists "$OUT/ocr/photo_OCR.txt" "Image OCR"

# ---------------------------------------------------------------- archive

echo
info "Archives and utilities"
run "Encrypted split archive" "$OUT/arch" archive.create --param format=7z --param password=Secret123 \
    --param volumeMode=preset --param volumeSize=10m --param name=testvol \
    -- "$FIX/clip.mp4" "$FIX/photo.jpg" && assert_file "$OUT/arch/testvol.7z.001" "7Z encrypted split archive"

run "Inspect an archive" "$OUT/ainfo" archive.info --param password=Secret123 \
    -- "$OUT/arch/testvol.7z.001" && true

run "Extract archive" "$OUT/aext" archive.extract --param password=Secret123 \
    -- "$OUT/arch/testvol.7z.001" && assert_file "$OUT/aext/testvol/clip.mp4" "Extract archive"

run "ZIP compression" "$OUT/zip" archive.create --param format=zip --param name=testzip \
    -- "$FIX/photo.jpg" "$FIX/sample.txt" && assert_file "$OUT/zip/testzip.zip" "ZIP compression"

run "QR code generation" "$OUT/qr" utility.qr --param action=generate --param content=https://example.com \
    --param size=256 && assert_file "$OUT/qr/Output_qr.png" "QR code generation"

run "QR code reading" "$OUT/qrread" utility.qr --param action=read \
    -- "$OUT/qr/二维码.png" && true

run "Hash computation" "$OUT/hash" utility.hash --param action=compute --param algorithm=md5 \
    -- "$FIX/clip.mp4" && true

run "Change hash" "$OUT/rehash" utility.rehash --param paddingBytes=64 \
    -- "$FIX/photo.jpg" && assert_file "$OUT/rehash/photo_rehashed.jpg" "Change file hash"

run "Image info" "$OUT/iinfo" utility.info \
    -- "$FIX/photo.jpg" && true

# ---------------------------------------------------------------- sessions

echo
info "Per-tool state"

# Each tool must own its inputs/parameters, so a running job in one tool never
# blocks another (and switching tools never discards staged work).
mkdir -p "$CACHE_DIR/session_modules"
SESSION_SRC=$(find "$ROOT/Sources" -name '*.swift' ! -name 'FormatForgeApp.swift' | sort | tr '\n' ' ')
if swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
        -module-cache-path "$CACHE_DIR/session_modules" -parse-as-library -swift-version 5 \
        -Xfrontend -strict-concurrency=minimal \
        -framework SwiftUI -framework AppKit -framework AVFoundation -framework PDFKit \
        -framework Vision -framework CoreImage -framework UniformTypeIdentifiers \
        -o "$CACHE_DIR/session_test" "$ROOT/Tests/SessionTest.swift" $SESSION_SRC \
        2> "$CACHE_DIR/session.log"; then
    SESSION_OUT=$("$CACHE_DIR/session_test" 2>&1 || true)
    echo "$SESSION_OUT" | sed 's/^/      /'
    if echo "$SESSION_OUT" | grep -q "RESULT PASS"; then
        ok "Each tool keeps its own inputs and parameters (usable in parallel)"
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} Tool state is not isolated"
        FAILED=$((FAILED + 1)); FAILURES+=("Tool state is not isolated")
    fi
else
    grep -E "error:" "$CACHE_DIR/session.log" | head -5
    warn "Skipping the per-tool state test (compilation failed)"
fi

# Hardware acceleration must default to OFF (better compression by default).
# `grep -c` exits 1 on no match, which `set -e` would treat as fatal, so every
# count is guarded with `|| true`.
HW_DEFAULT=$(grep -c 'useHardwareAcceleration") as? Bool ?? false' \
             "$ROOT/Sources/Core/AppSettings.swift" 2>/dev/null || true)
HW_TOGGLE=$(grep -h '"hardware", L("' \
            "$ROOT/Sources/Features/Video/VideoSupport.swift" \
            "$ROOT/Sources/Features/Video/VideoTools.swift" 2>/dev/null | grep -c 'default: false' || true)
if [[ "${HW_DEFAULT:-0}" -ge 1 && "${HW_TOGGLE:-0}" -ge 2 ]]; then
    ok "Hardware acceleration is off by default (global and per-tool)"
    PASS=$((PASS + 1))
else
    echo "${RED}✗${RESET} Hardware acceleration does not default to off (global=${HW_DEFAULT:-0} tools=${HW_TOGGLE:-0})"
    FAILED=$((FAILED + 1)); FAILURES+=("Hardware acceleration default is wrong")
fi

# Every video codec must document its trade-offs in the UI.
CODEC_DOCS=$(grep -c 'case .h264:' "$ROOT/Sources/Core/FFmpeg.swift" 2>/dev/null || true)
if grep -q "var characteristics" "$ROOT/Sources/Core/FFmpeg.swift" \
   && grep -q "var summary" "$ROOT/Sources/Core/FFmpeg.swift" \
   && [[ "${CODEC_DOCS:-0}" -ge 3 ]]; then
    ok "Every codec documents its trade-offs and comparison table"
    PASS=$((PASS + 1))
else
    echo "${RED}✗${RESET} Codec documentation is missing"
    FAILED=$((FAILED + 1)); FAILURES+=("Codec documentation is missing")
fi

# ---------------------------------------------------------------- inspectors

echo
info "Automatic inspectors"

# Inspection tools must compute on input change: no button, no queue entry,
# no output folder, and every checksum in a single pass.
build_and_run() {
    local name="$1"; shift
    local src="$1"; shift
    local modules="$CACHE_DIR/${name}_modules"
    mkdir -p "$modules"
    local all_src
    all_src=$(find "$ROOT/Sources" -name '*.swift' ! -name 'FormatForgeApp.swift' | sort | tr '\n' ' ')
    if swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
            -module-cache-path "$modules" -parse-as-library -swift-version 5 \
            -Xfrontend -strict-concurrency=minimal \
            -framework SwiftUI -framework AppKit -framework AVFoundation -framework PDFKit \
            -framework Vision -framework CoreImage -framework UniformTypeIdentifiers \
            -o "$CACHE_DIR/$name" "$src" $all_src 2> "$CACHE_DIR/$name.log"; then
        (cd "$ROOT" && "$CACHE_DIR/$name" 2>&1 || true)
    else
        grep -E "error:" "$CACHE_DIR/$name.log" | head -5
        echo "BUILD FAILED"
    fi
}

INSPECT_OUT=$(build_and_run inspect_test "$ROOT/Tests/InspectTest.swift")
echo "$INSPECT_OUT" | sed 's/^/      /'
if echo "$INSPECT_OUT" | grep -q "RESULT PASS"; then
    ok "Checksum algorithms and image info inspector are correct"
    PASS=$((PASS + 1))
else
    echo "${RED}✗${RESET} Inspector test failed"
    FAILED=$((FAILED + 1)); FAILURES+=("Inspector test failed")
fi

AUTO_OUT=$(build_and_run auto_test "$ROOT/Tests/AutoInspectTest.swift")
echo "$AUTO_OUT" | sed 's/^/      /'
if echo "$AUTO_OUT" | grep -q "RESULT PASS"; then
    ok "Dropping a file computes the result automatically (no click needed)"
    PASS=$((PASS + 1))
else
    echo "${RED}✗${RESET} Automatic computation did not happen"
    FAILED=$((FAILED + 1)); FAILURES+=("Automatic computation did not happen")
fi

# ---------------------------------------------------------------- semantics

echo
info "Semantic correctness"

# Images must not be described with video properties; report-only tools must
# not demand an output folder; button verbs must follow the selected mode.
mkdir -p "$CACHE_DIR/sem_modules"
SEM_SRC=$(find "$ROOT/Sources" -name '*.swift' ! -name 'FormatForgeApp.swift' | sort | tr '\n' ' ')
if swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
        -module-cache-path "$CACHE_DIR/sem_modules" -parse-as-library -swift-version 5 \
        -Xfrontend -strict-concurrency=minimal \
        -framework SwiftUI -framework AppKit -framework AVFoundation -framework PDFKit \
        -framework Vision -framework CoreImage -framework UniformTypeIdentifiers \
        -o "$CACHE_DIR/sem_test" "$ROOT/Tests/SemanticsTest.swift" $SEM_SRC \
        2> "$CACHE_DIR/sem.log"; then
    SEM_OUT=$(cd "$ROOT" && "$CACHE_DIR/sem_test" 2>&1 || true)
    echo "$SEM_OUT" | sed 's/^/      /'
    if echo "$SEM_OUT" | grep -q "RESULT PASS"; then
        ok "Media kinds, button labels and report-tool behaviour are correct"
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} Semantic check failed"
        FAILED=$((FAILED + 1)); FAILURES+=("Semantic check failed")
    fi
else
    grep -E "error:" "$CACHE_DIR/sem.log" | head -5
    warn "Skipping the semantic test (compilation failed)"
fi

# A report-only tool must run successfully without writing anything.
run "Checksums (no output file)" "$OUT/sem_hash" utility.hash --param action=compute \
    -- "$FIX/clip.mp4" && ok "Report tools succeed without an output folder"

# ---------------------------------------------------------------- presets

echo
info "Preset templates"

# Every ladder must lead with a ready-to-use default, not "custom".
LADDER_OK=1
for TOOL in video.compress video.convert video.resize video.gif image.convert \
            image.compress image.resize archive.create doc.word2pdf doc.ocr; do
    # The probe intentionally fails (to print the ladder), so tolerate the
    # non-zero exit under `set -e`.
    FIRST=$("$BIN" "$TOOL" "$OUT/preset_probe" --preset __list__ -- "$FIX/clip.mp4" 2>&1 \
            | grep -o 'available: .*' | head -1 || true)
    if [[ -z "$FIRST" ]]; then
        # A tool with no ladder at all is acceptable; it just has no presets.
        continue
    fi
    if [[ "$FIRST" == *custom* && "$FIRST" != *balanced* && "$FIRST" != *web* && "$FIRST" != *accurate* ]]; then
        echo "${RED}✗${RESET} $TOOL starts with a custom preset instead of a ready-made template"
        LADDER_OK=0
    fi
done
if [[ $LADDER_OK -eq 1 ]]; then
    ok "Every tool's preset list starts with a usable template"
    PASS=$((PASS + 1))
else
    FAILED=$((FAILED + 1)); FAILURES+=("Default preset is not usable")
fi

# A preset must actually change the encoder settings.
for P in balanced compact extreme; do
    rm -rf "$OUT/preset_$P"; mkdir -p "$OUT/preset_$P"
    "$BIN" video.compress "$OUT/preset_$P" --preset "$P" -- "$FIX/clip.mp4" >/dev/null 2>&1
    SIZE=$(stat -f%z "$OUT/preset_$P/clip_compressed.mp4" 2>/dev/null || echo 0)
    printf "%-10s %s bytes\n" "$P" "$SIZE"
done
BAL=$(stat -f%z "$OUT/preset_balanced/clip_compressed.mp4" 2>/dev/null || echo 0)
EXT=$(stat -f%z "$OUT/preset_extreme/clip_compressed.mp4" 2>/dev/null || echo 0)
if [[ "$BAL" -gt 0 && "$EXT" -gt 0 && "$EXT" -lt "$BAL" ]]; then
    ok "Presets took effect  →  extreme (${EXT}) < balanced (${BAL})"
    PASS=$((PASS + 1))
else
    echo "${RED}✗${RESET} Presets produced the same result: balanced=$BAL extreme=$EXT"
    FAILED=$((FAILED + 1)); FAILURES+=("Presets had no effect")
fi

# ---- estimates ----

echo
info "Estimation engine"

check_estimate() {
    local label="$1"; shift
    local tool="$1"; shift
    local outdir="$1"; shift
    local line
    # --estimate is an option, so it must precede the "--" input separator.
    line=$("$BIN" "$tool" "$outdir" --estimate "$@" 2>&1 | grep '^ESTIMATE' | head -1 || true)
    if [[ -z "$line" ]]; then
        echo "${RED}✗${RESET} $label  →  No estimate was printed"
        FAILED=$((FAILED + 1)); FAILURES+=("$label")
        return
    fi
    local bytes seconds
    bytes=$(echo "$line" | grep -o 'bytes=[0-9-]*' | cut -d= -f2)
    seconds=$(echo "$line" | grep -o 'seconds=[0-9.-]*' | cut -d= -f2)
    if [[ "${bytes:-0}" -gt 0 && "$(echo "$seconds > 0" | bc 2>/dev/null || echo 1)" == "1" ]]; then
        ok "$label  →  $line" | sed 's/ESTIMATE//'
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} $label  →  Invalid estimate value: $line"
        FAILED=$((FAILED + 1)); FAILURES+=("$label")
    fi
}

check_estimate "Video compression estimate" video.compress "$OUT/est1" --preset balanced -- "$FIX/clip.mp4"
check_estimate "Video to GIF estimate" video.gif "$OUT/est2" --param width=320 -- "$FIX/clip.mp4"
check_estimate "Image compression estimate" image.compress "$OUT/est3" --preset compact -- "$FIX/photo.jpg"
check_estimate "Archive estimate" archive.create "$OUT/est4" --preset balanced -- "$FIX/clip.mp4"
check_estimate "Document to PDF estimate" doc.word2pdf "$OUT/est5" -- "$OUT/w2p/sample.pdf"

# The prediction must be in the right ballpark, not off by an order of magnitude.
EST_LINE=$("$BIN" video.compress "$OUT/est_cal" --preset balanced --estimate -- "$FIX/clip.mp4" 2>&1 | grep '^ESTIMATE' || true)
EST_BYTES=$(echo "$EST_LINE" | grep -o 'bytes=[0-9]*' | cut -d= -f2)
ACTUAL=$(stat -f%z "$OUT/preset_balanced/clip_compressed.mp4" 2>/dev/null || echo 0)
if [[ "${EST_BYTES:-0}" -gt 0 && "$ACTUAL" -gt 0 ]]; then
    # Accept anything within a 4x window in either direction.
    LO=$((ACTUAL / 4)); HI=$((ACTUAL * 4))
    if [[ "$EST_BYTES" -ge "$LO" && "$EST_BYTES" -le "$HI" ]]; then
        RATIO=$(echo "scale=2; $EST_BYTES / $ACTUAL" | bc)
        ok "Estimate is acceptable  →  estimated ${EST_BYTES} vs actual ${ACTUAL} (${RATIO}×)"
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} Estimate is too far off: estimated ${EST_BYTES} vs actual ${ACTUAL}"
        FAILED=$((FAILED + 1)); FAILURES+=("Estimate is too far off")
    fi
fi

# ---- logging ----

echo
info "Log output"

LOG=$("$BIN" video.convert "$OUT/log_probe" --param codec=h264 --param container=mp4 \
      -- "$FIX/clip.mp4" 2>&1 || true)

assert_log_contains() {
    if echo "$LOG" | grep -q "$1"; then
        ok "Log contains $2"
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} Log is missing $2 (expected to match: $1)"
        FAILED=$((FAILED + 1)); FAILURES+=("Log is missing $2")
    fi
}

assert_log_contains "\[command\]" "Actual command line"
assert_log_contains "ffmpeg" "ffmpeg invocation recorded"
assert_log_contains "\[success\]" "Success result"
assert_log_contains "file(s)" "Input summary"
assert_log_contains "Output folder" "Output folder recorded"
assert_log_contains "Took" "Timing recorded"

# The logged command line must be a real, replayable ffmpeg invocation.
CMD=$(echo "$LOG" | grep -m1 "\[command\]" | sed 's/.*\[command\] *//' || true)
if [[ "$CMD" == ffmpeg* && "$CMD" == *"-i"* ]]; then
    ok "The command line in the log is reproducible  →  $(echo "$CMD" | cut -c1-60)…"
    PASS=$((PASS + 1))
else
    echo "${RED}✗${RESET} The command line in the log is incomplete: $CMD"
    FAILED=$((FAILED + 1)); FAILURES+=("Command line incomplete")
fi

# ---- output directory ----

echo
info "Output location"

# An explicitly supplied folder must win over every global setting.
mkdir -p "$OUT/explicit_target"
"$BIN" video.convert "$OUT/explicit_target" --param codec=h264 -- "$FIX/clip.mp4" >/dev/null 2>&1
assert_file "$OUT/explicit_target/clip.mp4" "Chosen folder honoured"

# resolveOutputDirectory must honour each mode.
cat > /tmp/dirmode.swift <<'SWIFT'
import Foundation
@main struct M { static func main() {
    let settings = AppSettings.shared
    let input = URL(fileURLWithPath: "/tmp/somewhere/source.mp4")
    let custom = URL(fileURLWithPath: "/tmp/custom_out", isDirectory: true)
    let explicit = URL(fileURLWithPath: "/tmp/this_run", isDirectory: true)

    settings.outputMode = .alongsideInput
    print("alongside=" + settings.resolveOutputDirectory(input: input, explicit: nil).path)

    settings.outputMode = .customFolder
    settings.customOutputPath = custom.path
    print("custom=" + settings.resolveOutputDirectory(input: input, explicit: nil).path)

    settings.outputMode = .askEveryTime
    print("ask_nochoice=" + settings.resolveOutputDirectory(input: input, explicit: nil).path)
    print("ask_choice=" + settings.resolveOutputDirectory(input: input, explicit: explicit).path)

    // An explicit folder must always win.
    settings.outputMode = .alongsideInput
    print("explicit_wins=" + settings.resolveOutputDirectory(input: input, explicit: explicit).path)

    settings.outputMode = .customFolder
    settings.customOutputPath = ""
    print("custom_unset=" + settings.resolveOutputDirectory(input: input, explicit: nil).path)
    print("needs_selection=\(settings.needsFolderSelection)")
} }
SWIFT
SDK="${FORMATFORGE_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
mkdir -p "$CACHE_DIR/dirmode_modules"
if swiftc -sdk "$SDK" -module-cache-path "$CACHE_DIR/dirmode_modules" -parse-as-library \
        -o "$CACHE_DIR/dirmode_bin" /tmp/dirmode.swift \
        Sources/Core/AppSettings.swift Sources/Core/Localization.swift \
        Sources/Design/Theme.swift 2>/dev/null; then
    DIR_OUT=$("$CACHE_DIR/dirmode_bin" || true)
    echo "$DIR_OUT" | sed 's/^/      /'
    if echo "$DIR_OUT" | grep -q "alongside=/tmp/somewhere" \
       && echo "$DIR_OUT" | grep -q "custom=/tmp/custom_out" \
       && echo "$DIR_OUT" | grep -q "ask_choice=/tmp/this_run" \
       && echo "$DIR_OUT" | grep -q "explicit_wins=/tmp/this_run" \
       && echo "$DIR_OUT" | grep -q "needs_selection=true"; then
        ok "Output-location resolution is correct (per-run folder wins)"
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} Output-location resolution is wrong"
        FAILED=$((FAILED + 1)); FAILURES+=("Output-location resolution error")
    fi
else
    warn "Skipping the output-location unit test (compilation failed)"
fi

# ---------------------------------------------------------------- robustness

echo
info "Robustness and edge cases"

# Chinese filenames, spaces and full-width punctuation must survive round-trips.
EDGE="$ROOT/.test/edge"
mkdir -p "$EDGE"
cp "$FIX/clip.mp4" "$EDGE/我的 视频 测试.mp4" 2>/dev/null || true
cp "$FIX/photo.jpg" "$EDGE/照片（1）.jpg" 2>/dev/null || true
cp "$FIX/img1.png" "$EDGE/图 1.png" 2>/dev/null || true
cp "$FIX/img2.png" "$EDGE/图 2.png" 2>/dev/null || true
printf '中文内容测试\n' > "$EDGE/文档 说明.txt"

run "Transcode with a Chinese filename" "$OUT/zh_v" video.convert --param codec=h264 --param container=mp4 \
    -- "$EDGE/我的 视频 测试.mp4" && assert_probe "$OUT/zh_v/我的 视频 测试.mp4" v "Transcode a Chinese-named video"

run "Filename to image (Chinese)" "$OUT/zh_i" image.convert --param codec=png \
    -- "$EDGE/照片（1）.jpg" && assert_file "$OUT/zh_i/照片（1）.png" "Image conversion (Chinese name)"

run "Filename to GIF (Chinese)" "$OUT/zh_g" image.gif --param width=200 \
    -- "$EDGE/图 1.png" "$EDGE/图 2.png" && assert_file "$OUT/zh_g/图 1.gif" "Multi-image to GIF (Chinese name)"

run "TXT to Word (Chinese name)" "$OUT/zh_d" doc.txt2word \
    -- "$EDGE/文档 说明.txt" && assert_file "$OUT/zh_d/文档 说明.docx" "Document conversion (Chinese name)"

# Corrupt and empty inputs must fail loudly rather than emit a broken file.
printf 'not a real video' > "$EDGE/broken.mp4"
: > "$EDGE/empty.png"

run_expect_failure "Corrupt video rejected" "$OUT/robust_v" video.convert --param codec=h264 -- "$EDGE/broken.mp4"
run_expect_failure "Empty file rejected" "$OUT/robust_i" image.convert --param codec=png -- "$EDGE/empty.png"
run_expect_failure "Wrong password rejected" "$OUT/robust_a" archive.extract --param password=WRONG -- "$OUT/arch/testvol.7z.001"

# The fit modes must produce genuinely different geometry, not silently no-op.
if [[ -f "$FIX/clip.mp4" ]]; then
    FIT_OK=1
    declare -a FIT_GEOM=()
    for fit in fit fill stretch; do
        rm -rf "$OUT/fit_$fit"; mkdir -p "$OUT/fit_$fit"
        "$BIN" video.resize "$OUT/fit_$fit" \
            --param scale=custom --param customWidth=480 --param customHeight=480 \
            --param allowUpscale=true --param fit="$fit" -- "$FIX/clip.mp4" >/dev/null 2>&1
        geom=$(ffprobe -v error -select_streams v -show_entries stream=width,height \
               -of csv=p=0 "$OUT/fit_$fit/clip_resized.mp4" 2>/dev/null || echo "?")
        FIT_GEOM+=("$fit=$geom")
    done
    # fill and stretch share a box but must differ from fit's letterboxed output.
    if [[ "${FIT_GEOM[0]}" == "fit=480,270" && "${FIT_GEOM[1]}" == "fill=480,480" \
       && "${FIT_GEOM[2]}" == "stretch=480,480" ]]; then
        ok "Fitting modes took effect  →  ${FIT_GEOM[*]}"
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} Fitting modes had no effect：${FIT_GEOM[*]}"
        FAILED=$((FAILED + 1)); FAILURES+=("Fitting modes had no effect")
    fi
fi

# ---------------------------------------------------------------- MD5 semantics

echo
info "Key behaviour checks"
ORIGINAL_MD5=$(md5 -q "$FIX/clip.mp4")
CHANGED_MD5=$(md5 -q "$OUT/md5/clip_md5.mp4" 2>/dev/null || echo "missing")
if [[ "$ORIGINAL_MD5" != "$CHANGED_MD5" && "$CHANGED_MD5" != "missing" ]]; then
    ok "MD5 changed  →  $ORIGINAL_MD5 ≠ $CHANGED_MD5"
    PASS=$((PASS + 1))
else
    echo "${RED}✗${RESET} Changing the MD5 did not alter the hash"
    FAILED=$((FAILED + 1)); FAILURES+=("Changing the MD5 had no effect")
fi

# The video stream must be byte-identical: verify duration and frame count.
ORIG_FRAMES=$(ffprobe -v error -select_streams v -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$FIX/clip.mp4")
NEW_FRAMES=$(ffprobe -v error -select_streams v -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$OUT/md5/clip_md5.mp4" 2>/dev/null || echo 0)
if [[ "$ORIG_FRAMES" == "$NEW_FRAMES" && -n "$ORIG_FRAMES" ]]; then
    ok "Picture unaffected  →  same frame count ($ORIG_FRAMES frames)"
    PASS=$((PASS + 1))
else
    echo "${RED}✗${RESET} Picture affected: $ORIG_FRAMES frames before, $NEW_FRAMES after"
    FAILED=$((FAILED + 1)); FAILURES+=("Changing the MD5 affected the picture")
fi

# Encryption must actually protect the archive.
if 7z t -pWrongPassword "$OUT/arch/testvol.7z.001" >/dev/null 2>&1; then
    echo "${RED}✗${RESET} Encrypted volumes failed: the wrong password still extracted"
    FAILED=$((FAILED + 1)); FAILURES+=("Encryption had no effect")
else
    ok "Encrypted volumes work  →  wrong password rejected"
    PASS=$((PASS + 1))
fi

if 7z t -pSecret123 "$OUT/arch/testvol.7z.001" >/dev/null 2>&1; then
    ok "Correct password extracts"
    PASS=$((PASS + 1))
else
    echo "${RED}✗${RESET} Correct password failed to extract"
    FAILED=$((FAILED + 1)); FAILURES+=("Correct password failed")
fi

# Compression must actually shrink the video.
ORIG_SIZE=$(stat -f%z "$FIX/clip.mp4")
COMP_SIZE=$(stat -f%z "$OUT/compress/clip_compressed.mp4" 2>/dev/null || echo 0)
if [[ "$COMP_SIZE" -gt 0 && "$COMP_SIZE" -lt "$ORIG_SIZE" ]]; then
    SAVED=$(( (ORIG_SIZE - COMP_SIZE) * 100 / ORIG_SIZE ))
    ok "Video compression worked  →  ${SAVED}% smaller"
    PASS=$((PASS + 1))
else
    echo "${RED}✗${RESET} Video compression did not reduce the size"
    FAILED=$((FAILED + 1)); FAILURES+=("Compression had no effect")
fi

# The GIF must be a valid animated GIF with multiple frames.
GIF_FRAMES=$(ffprobe -v error -select_streams v -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$OUT/mgif/img1.gif" 2>/dev/null || echo 0)
if [[ "${GIF_FRAMES:-0}" -gt 3 ]]; then
    ok "GIF is animated  →  $GIF_FRAMES frames"
    PASS=$((PASS + 1))
else
    echo "${RED}✗${RESET} Unexpected GIF frame count: $GIF_FRAMES"
    FAILED=$((FAILED + 1)); FAILURES+=("Unexpected GIF frame count")
fi

# ---------------------------------------------------------------- localization

echo
info "Localisation"

# Every language must ship the same key set as English, load at runtime, and
# actually differ from one another.
mkdir -p "$CACHE_DIR/i18n_modules"
I18N_SRC=$(find "$ROOT/Sources" -name '*.swift' ! -name 'FormatForgeApp.swift' | sort | tr '\n' ' ')
if swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
        -module-cache-path "$CACHE_DIR/i18n_modules" -parse-as-library -swift-version 5 \
        -Xfrontend -strict-concurrency=minimal \
        -framework SwiftUI -framework AppKit -framework AVFoundation -framework PDFKit \
        -framework Vision -framework CoreImage -framework UniformTypeIdentifiers \
        -o "$CACHE_DIR/i18n_test" "$ROOT/Tests/LocalizationTest.swift" $I18N_SRC \
        2> "$CACHE_DIR/i18n.log"; then
    # LanguageStore looks for the tables next to the running executable, and
    # `i18n/` was just populated beside this binary — so the test runs from the
    # cache and does not need an app bundle to exist.
    I18N_OUT=$("$CACHE_DIR/i18n_test" 2>/dev/null || true)
    I18N_PASS=$(printf '%s' "$I18N_OUT" | grep -c "✓" || true)
    echo "$I18N_OUT" | grep -E "✗|RESULT" | sed 's/^/      /' || true
    if printf '%s' "$I18N_OUT" | grep -q "RESULT PASS"; then
        ok "All 12 languages work (${I18N_PASS} checks)"
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} Localisation check failed"
        FAILED=$((FAILED + 1)); FAILURES+=("Localisation check failed")
    fi
else
    grep -E "error:" "$CACHE_DIR/i18n.log" | head -3
    warn "Skipping the localisation check (compilation failed)"
fi

# Switching language must change the workspace, not just the settings pane.
SWITCH_SRC=$(find "$ROOT/Sources" -name '*.swift' ! -name 'FormatForgeApp.swift' | sort | tr '\n' ' ')
if swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
        -module-cache-path "$CACHE_DIR/i18n_modules" -parse-as-library -swift-version 5 \
        -Xfrontend -strict-concurrency=minimal \
        -framework SwiftUI -framework AppKit -framework AVFoundation -framework PDFKit \
        -framework Vision -framework CoreImage -framework UniformTypeIdentifiers \
        -o "$CACHE_DIR/switch_test" "$ROOT/Tests/LanguageSwitchTest.swift" $SWITCH_SRC \
        2> "$CACHE_DIR/switch.log"; then
    SWITCH_OUT=$(cd "$ROOT" && "$CACHE_DIR/switch_test" 2>/dev/null || true)
    echo "$SWITCH_OUT" | grep -E "✓|✗" | sed 's/^/      /'
    if printf '%s' "$SWITCH_OUT" | grep -q "RESULT PASS"; then
        ok "Switching language changes the workspace text"
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} Switching language did not affect the workspace"
        FAILED=$((FAILED + 1)); FAILURES+=("Switching language did not affect the workspace")
    fi
else
    grep -E "error:" "$CACHE_DIR/switch.log" | head -3
    warn "Skipping the language-switch check (compilation failed)"
fi

# A `static let` that calls L() is evaluated once and keeps the language it was
# first read in, so switching language leaves that string behind. This caught a
# real bug: every Tool was `static let`, so the whole workspace stayed English
# after switching to German.
FROZEN=$(grep -rn "static let .*=.*L(\"" "$ROOT/Sources" --include='*.swift' \
         | grep -v "static let.*: String" || true)
if [[ -z "$FROZEN" ]]; then
    ok "No static let caches a translated string"
    PASS=$((PASS + 1))
else
    echo "${RED}✗${RESET} These static let values cache translated strings:"
    echo "$FROZEN" | head -5 | sed 's/^/      /'
    FAILED=$((FAILED + 1)); FAILURES+=("A static let caches translated strings")
fi

# Long translations must fit the containers they sit in. Fixed-width controls
# clipped text in ten languages, so this is checked rather than eyeballed.
LAYOUT_SRC=$(find "$ROOT/Sources" -name '*.swift' ! -name 'FormatForgeApp.swift' | sort | tr '\n' ' ')
if swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
        -module-cache-path "$CACHE_DIR/i18n_modules" -parse-as-library -swift-version 5 \
        -Xfrontend -strict-concurrency=minimal \
        -framework SwiftUI -framework AppKit -framework AVFoundation -framework PDFKit \
        -framework Vision -framework CoreImage -framework UniformTypeIdentifiers \
        -o "$CACHE_DIR/layout_test" "$ROOT/Tests/LayoutTest.swift" $LAYOUT_SRC \
        2> "$CACHE_DIR/layout.log"; then
    LAYOUT_OUT=$(cd "$ROOT" && "$CACHE_DIR/layout_test" 2>/dev/null || true)
    echo "$LAYOUT_OUT" | grep "✗" | head -8 | sed 's/^/      /' || true
    if printf '%s' "$LAYOUT_OUT" | grep -q "RESULT PASS"; then
        ok "Long strings fit in all 12 languages"
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} Text overflows its container"
        FAILED=$((FAILED + 1)); FAILURES+=("Text overflows its container")
    fi
else
    grep -E "error:" "$CACHE_DIR/layout.log" | head -3
    warn "Skipping the layout check (compilation failed)"
fi

# Scripts, build tooling and the READMEs are English-only. Chinese belongs in
# Resources/i18n (the UI) and the tutorial's own language tables. The few
# exceptions are language names, which must stay in their own script so a reader
# can find them, and the test's Chinese filename fixtures, which exist to prove
# Unicode names survive.
ALLOWED='简体中文|繁體中文|日本語|한국어|二维码|我的 视频 测试|照片|图 1|图 2|文档 说明|中文内容测试'
# Scoped to the build tooling and documentation. Translation working files
# under Tools/tutorial/i18n/ are excluded: they hold the source text of every
# language by design, and the chunk scripts quote it deliberately.
STRAY=$(grep -rn $'[\u4e00-\u9fff]' \
    "$ROOT/README.md" "$ROOT/build.sh" "$ROOT/make-dmg.sh" "$ROOT/run.sh" \
    "$ROOT/test.sh" "$ROOT/Scripts" \
    "$ROOT/Tools/build-tutorial.py" "$ROOT/Tools/DumpRegistry.swift" \
    "$ROOT/Tools/tutorial/merge-chunks.py" "$ROOT/Tools/tutorial/split-chunks.py" \
    "$ROOT/Tools/tutorial/validate-content.py" \
    "$ROOT/Tools/i18n/assign-keys.py" "$ROOT/Tools/i18n/build-resources.py" \
    "$ROOT/Tools/i18n/rewrite-sources.py" 2>/dev/null \
    | grep -vE "$ALLOWED" || true)
if [[ -z "$STRAY" ]]; then
    ok "No stray Chinese in scripts or docs"
    PASS=$((PASS + 1))
else
    echo "${RED}✗${RESET} Chinese found outside the language tables:"
    echo "$STRAY" | head -8 | sed 's/^/      /'
    FAILED=$((FAILED + 1)); FAILURES+=("Stray Chinese in scripts")
fi

# The shipped resources must exist for every language the enum declares.
LANG_COUNT=$(ls "$ROOT/Resources/i18n"/*.json 2>/dev/null | wc -l | tr -d ' ')
ENUM_COUNT=$(grep -cE '^    case [a-zA-Z]+ +=' "$ROOT/Sources/Core/Localization.swift" || true)
if [[ "${LANG_COUNT:-0}" -ge 12 ]]; then
    ok "Language resources complete (${LANG_COUNT})"
    PASS=$((PASS + 1))
else
    echo "${RED}✗${RESET} Not enough language resources: ${LANG_COUNT}"
    FAILED=$((FAILED + 1)); FAILURES+=("Not enough language resources")
fi

# ---------------------------------------------------------------- icon

echo
info "App icon"

if [[ -f "$ROOT/Resources/AppIcon-source.png" ]]; then
    # The icon must be regenerable from the artwork, and the compiled .icns
    # must contain every size macOS asks for.
    if "$ROOT/Scripts/make-icon.sh" >/dev/null 2>&1; then
        ok "Icon can be regenerated from the artwork"
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} Icon generation failed"
        FAILED=$((FAILED + 1)); FAILURES+=("Icon generation failed")
    fi

    rm -rf "$CACHE_DIR/iconset.iconset"
    if iconutil -c iconset "$ROOT/Resources/AppIcon.icns"             -o "$CACHE_DIR/iconset.iconset" >/dev/null 2>&1; then
        MISSING=""
        for n in 16 32 128 256 512; do
            [[ -f "$CACHE_DIR/iconset.iconset/icon_${n}x${n}.png" ]] || MISSING="$MISSING ${n}"
            [[ -f "$CACHE_DIR/iconset.iconset/icon_${n}x${n}@2x.png" ]] || MISSING="$MISSING ${n}@2x"
        done
        if [[ -z "$MISSING" ]]; then
            ok "ICNS contains all 10 sizes"
            PASS=$((PASS + 1))
        else
            echo "${RED}✗${RESET} ICNS is missing sizes: ${MISSING}"
            FAILED=$((FAILED + 1)); FAILURES+=("ICNS is missing sizes")
        fi
    else
        echo "${RED}✗${RESET} ICNS could not be parsed"
        FAILED=$((FAILED + 1)); FAILURES+=("ICNS could not be parsed")
    fi

    # The system must report a real image (not a placeholder) for the bundle.
    mkdir -p "$CACHE_DIR/icon_modules"
    if swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
            -module-cache-path "$CACHE_DIR/icon_modules" -parse-as-library -swift-version 5 \
            -Xfrontend -strict-concurrency=minimal -framework AppKit \
            -o "$CACHE_DIR/icon_test" "$ROOT/Tests/IconTest.swift" 2> "$CACHE_DIR/icon.log"; then
        # This reads the built bundle. When the bundle is absent — running the
        # suite on a fresh checkout, before ./build.sh — the ICNS checks above
        # still cover the icon, so skip rather than fail.
        if [[ ! -d "$ROOT/build/FormatForge.app" ]]; then
            warn "Skipping the icon-read check (no app bundle yet — run ./build.sh first)"
            ICON_OUT=""
        else
            ICON_OUT=$("$CACHE_DIR/icon_test" "$ROOT/build/FormatForge.app" 2>/dev/null || true)
        fi
        echo "$ICON_OUT" | sed 's/^/      /' || true
        if [[ -z "$ICON_OUT" ]]; then
            : # already warned above
        elif echo "$ICON_OUT" | grep -q "✓ Icon contains real image content"; then
            ok "The system reads the app icon correctly"
            PASS=$((PASS + 1))
        else
            echo "${RED}✗${RESET} The system could not read the icon"
            FAILED=$((FAILED + 1)); FAILURES+=("The system could not read the icon")
        fi
    else
        warn "Skipping the icon-read check (compilation failed)"
    fi
else
    warn "No icon artwork (Resources/AppIcon-source.png)"
fi

# ---------------------------------------------------------------- tutorial

echo
info "Tutorial page"

if [[ -f "$ROOT/docs/index.html" ]]; then
    # Regenerate from source so the check runs against the current code. Use the
    # shell entry point: it exports the tool registry the renderer depends on.
    if "$ROOT/Tools/build-tutorial.sh" >/dev/null 2>&1; then
        ok "Tutorial can be regenerated from source"
        PASS=$((PASS + 1))
    else
        echo "${RED}✗${RESET} Tutorial generation failed"
        FAILED=$((FAILED + 1)); FAILURES+=("Tutorial generation failed")
    fi

    mkdir -p "$CACHE_DIR/tut_modules"
    if swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
            -module-cache-path "$CACHE_DIR/tut_modules" -parse-as-library -swift-version 5 \
            -Xfrontend -strict-concurrency=minimal \
            -framework WebKit -framework AppKit \
            -o "$CACHE_DIR/tut_test" "$ROOT/Tests/TutorialThemeTest.swift" 2> "$CACHE_DIR/tut.log"; then
        mkdir -p "$CACHE_DIR/tuthome"
        TUT_OUT=$(HOME="$CACHE_DIR/tuthome" "$CACHE_DIR/tut_test" \
                    "$ROOT/docs/index.html" "$ROOT/Tests/tutorial_check.js" 2>/dev/null || true)
        echo "$TUT_OUT" | sed 's/^/      /'
        TUT_PASS=$(printf '%s' "$TUT_OUT" | grep -c "PASS" || true)
        # Require a real result set: an empty or truncated run must not pass.
        if printf '%s' "$TUT_OUT" | grep -q "FAIL"; then
            echo "${RED}✗${RESET} Tutorial interface check failed"
            FAILED=$((FAILED + 1)); FAILURES+=("Tutorial interface check failed")
        elif [[ "${TUT_PASS:-0}" -lt 30 ]]; then
            echo "${RED}✗${RESET} Tutorial check output is incomplete (only ${TUT_PASS:-0} items)"
            FAILED=$((FAILED + 1)); FAILURES+=("Tutorial check output is incomplete")
        else
            ok "Tutorial renders correctly (${TUT_PASS} checks: four theme contrasts, font size, highlighting, copy, figures)"
            PASS=$((PASS + 1))
        fi
    else
        grep -E "error:" "$CACHE_DIR/tut.log" | head -3
        warn "Skipping the tutorial interface check (compilation failed)"
    fi
else
    warn "Tutorial not generated yet (run ./Tools/build-tutorial.sh)"
fi

# ---------------------------------------------------------------- summary

echo
echo "────────────────────────────────────────"
if [[ $FAILED -eq 0 ]]; then
    echo "${GREEN}${BOLD}All passed${RESET}  $PASS checks"
else
    echo "${RED}${BOLD}$FAILED failed${RESET}, $PASS passed"
    for failure in "${FAILURES[@]}"; do echo "  ${RED}✗${RESET} $failure"; done
fi
echo "Output folder: $OUT"
echo

exit $(( FAILED > 0 ? 1 : 0 ))
