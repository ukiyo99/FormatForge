# Changelog

## 1.0.0

First release.

**Tools** — 53 in total: 18 video, 10 image, 17 document, 3 archive, 5 utility.
See the README for the full list.

**Languages** — 12, at roughly 1,180 strings each: English (default),
简体中文, 繁體中文, 日本語, 한국어, Français, Deutsch, Español, Português,
Русский, Italiano, Nederlands.

**Tutorial** — the HTML walkthrough of the codebase ships in five languages
(English, 简体中文, 日本語, 한국어, Français), switched from the toolbar. All five
live in the same file as `data-lang` spans, so switching is instant, works from
`file://`, and the source excerpts are stored only once.

**Packaging** — universal binary (arm64 + x86_64), self-contained DMG with
ffmpeg, ffprobe, 7z and cwebp bundled, so no Homebrew or other prerequisites.

### Notes on decisions that took a while to get right

- Tools are split into three kinds — inspectors, converters, and in-place
  operations — because making everything a converter meant "calculate a
  checksum" asked you where to save the output.
- Each tool keeps its own state, so you can run a long encode in one and work in
  another at the same time.
- Hardware encoding is off by default: it's faster but produces noticeably
  larger files, and this is a conversion tool.
- UI strings never drive logic. An earlier version picked a colour by checking
  whether a label contained a particular word, which worked in Chinese and broke
  in every other language.
