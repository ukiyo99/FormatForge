#!/usr/bin/env python3
"""Translate Tools/tutorial/i18n/chunks/en/b2.json (zh -> en) in place structurally.

Keys and list lengths are copied programmatically from the source; only the
string leaves are replaced with translations from TRANS.
"""
import json
import re
import sys

SRC = "Tools/tutorial/i18n/chunks/en/b2.json"
DST = "Tools/tutorial/i18n/chunks/en/b2.out.json"

TRANS = {
    "pdf.toimage": {
        "idea": "Use PDFKit to rasterize each page at a chosen DPI. The tricky part is the coordinate system: the PDF origin sits in the bottom-left corner, and everything has to be scaled by the DPI factor.",
        "how": [
            "Work out the scale factor <code>DPI \u00f7 72</code> (PDF's baseline is 72 DPI).",
            "Create a CGContext at the matching pixel size.",
            "Apply <code>scaleBy</code> then <code>translateBy</code> to map the PDF page coordinates onto the target canvas.",
            "Render and write out page by page.",
        ],
    },
    "image.rename": {
        "idea": "The biggest risk in batch renaming is <b>name collisions</b> \u2014 if a becomes b while b becomes c, renaming directly makes the files overwrite each other.",
        "how": [
            "Sort the files by the chosen rule and build the complete \"source \u2192 target\" plan.",
            "During execution, rename to a random temporary name first and then to the target name, so chained collisions can't happen.",
            "The template supports <code>{n}</code> for the sequence number, <code>{name}</code> for the original name, <code>{date}</code> for the date, <code>{i}</code> for the original index, and <code>{ext}</code> for the extension.",
            "Preview mode is on by default: it shows the plan without actually renaming anything.",
        ],
    },
    "utility.qr": {
        "idea": "Generate with CoreImage's <code>CIQRCodeGenerator</code> and decode with Vision.",
        "how": [
            "Generation: <code>CIQRCodeGenerator</code> produces the QR code, <code>CIFalseColor</code> applies the colors, and the result is scaled up to the target size.",
            "Error correction maps to four levels, L/M/Q/H: the higher the level, the more damage it tolerates, but the denser the modules.",
            "Decoding: <code>VNDetectBarcodesRequest</code>, which covers QR, Aztec, Code128, EAN13, PDF417 and DataMatrix.",
        ],
    },
    "utility.rehash": {
        "idea": "Change a file's hash without changing its contents \u2014 append random bytes to the end of the file.",
        "how": [
            "Copy the original file, then append N random bytes (in append mode the existing content is left completely untouched).",
            "Recompute the MD5 and record the old and new values to confirm it really changed.",
            "For formats like ZIP and PDF, bytes appended at the end usually don't stop the file from opening normally.",
        ],
        "notes": [
            "This tool <b>writes files</b>, unlike the read-only \"File Checksum\" tool \u2014 the two are separate. The inspector never modifies any file.",
        ],
    },
    "doc.word2pdf": {
        "idea": "Use CoreText's <code>CTFramesetter</code> to paginate automatically; it's more reliable than working out line breaks by hand.",
        "how": [
            "Read the source document into an <code>NSAttributedString</code>.",
            "Create a <code>CTFramesetter</code> and lay out one frame in the page area.",
            "Use <code>CTFrameGetVisibleStringRange</code> to see how much text fit on this page, then continue from there onto the next page until all the text is laid out.",
            "Cap it at 5000 pages so malformed input can't cause an infinite loop.",
        ],
    },
    "doc.pdf2word": {
        "idea": "A PDF's text layer has to be <b>reassembled</b> \u2014 the line breaks in a PDF come from layout positions, not from paragraph boundaries.",
        "how": [
            "Pull <code>page.string</code> from each page with PDFKit.",
            "Merge <code>-\\n</code> (hyphenated line breaks), turn single newlines into spaces, and collapse runs of spaces.",
            "Insert a separator between pages.",
            "When there's no text layer, fail with a clear error and suggest OCR instead of producing an empty document.",
        ],
    },
    "doc.txt2word": {
        "idea": "Line breaks in plain text are hard breaks, so converting them as-is gives you fragmented paragraphs \u2014 they need to be <b>merged intelligently</b>.",
        "how": [
            "Treat blank lines as paragraph boundaries.",
            "Accumulate non-blank lines in a buffer and only join them into a paragraph (with spaces) once a blank line shows up.",
            "Optional \"detect heading lines\": short all-caps lines, or lines starting with <code>#</code>, get heading styling.",
        ],
    },
    "doc.word2txt": {
        "idea": "Extract plain text, with an option to keep or drop paragraph breaks.",
        "how": [
            "Read the file as rich text, then take <code>.string</code>.",
            "With \"keep paragraph breaks\" turned off, replace newlines with spaces to get continuous text.",
        ],
    },
    "doc.word2md": {
        "idea": "The reverse conversion <b>infers syntax from font traits</b>. See \"Our own bidirectional Markdown converter\" for details.",
        "how": [
            "Split the text wherever the attributes change.",
            "Font size \u2265 24pt \u2192 <code>#</code>, \u2265 20pt \u2192 <code>##</code>, and so on.",
            "Bold + italic \u2192 <code>***</code>; monospaced \u2192 backticks; a link attribute \u2192 link syntax.",
            "<code>NSParagraphStyle.textLists</code> \u2192 list markers.",
        ],
    },
    "doc.pdf2md": {
        "idea": "Same extraction logic as PDF \u2192 Word, but the output is Markdown, with a separator between pages.",
        "how": [
            "Extract and concatenate the text page by page.",
            "Insert a <code>---</code> separator between pages.",
        ],
    },
    "doc.md2word": {
        "idea": "Our own Markdown parser renders it into styled rich text.",
        "how": [
            "Classify each line: heading, list, blockquote, code fence, table or paragraph.",
            "Parse inline markup in a single pass (bold, italic, code, links, images).",
            "Emit whole code fences in a monospaced font on a gray background.",
        ],
    },
    "doc.md2pdf": {
        "idea": "Render the Markdown into rich text first, then paginate and export to PDF with CoreText.",
        "how": [
            "Reuse the Markdown parser to get rich text.",
            "Compute the usable area for A4/Letter/A3 and lay out page by page.",
        ],
    },
    "doc.txt2pdf": {
        "idea": "The same smart paragraph merging as TXT \u2192 Word, followed by a PDF export.",
        "how": [
            "Merge paragraphs that hard line breaks had split apart.",
            "Optionally detect heading lines and enlarge their font size.",
            "Paginate to the page size.",
        ],
    },
    "doc.tortf": {
        "idea": "RTF is the most compatible rich text format \u2014 practically every word processor can open it.",
        "how": [
            "Write it out directly with <code>NSAttributedString.data(documentAttributes:)</code>.",
            "Fall back to the system's <code>textutil</code> if that fails.",
        ],
    },
    "doc.tohtml": {
        "idea": "Output HTML so it can go straight onto a web page.",
        "how": [
            "Generate it with the system HTML writer, keeping the basic styling and links.",
        ],
    },
    "doc.toodt": {
        "idea": "ODT is the open format shared by LibreOffice and WPS.",
        "how": [
            "Prefer the system writer; when it isn't supported, route through RTF and let textutil do the conversion.",
        ],
    },
    "doc.pdfmerge": {
        "idea": "When merging PDFs, turn the first page of each source file into a bookmark so you can still jump around quickly afterwards.",
        "how": [
            "Create an empty PDFDocument and insert the pages of each source file in turn.",
            "Record the index of each source file's first page and create a <code>PDFOutline</code> node for it.",
            "Attach the nodes to <code>outlineRoot</code>.",
        ],
    },
    "doc.pdfsplit": {
        "idea": "Three ways to split: one file per N pages, one file per page, or extract a specific range.",
        "how": [
            "Loop over the page count, creating a new PDFDocument and inserting the matching pages each time.",
            "Name the output files with a part number or the page range.",
        ],
    },
    "doc.pdfcompress": {
        "idea": "Scanned files are big mainly because of the high-resolution images embedded in them, so <b>rasterize each page to a lower-DPI JPEG and put that back in</b>.",
        "how": [
            "Work out the scale factor from the target DPI and render each page to a bitmap.",
            "Re-encode at the chosen JPEG quality.",
            "Replace the original pages with the new ones.",
        ],
        "notes": [
            "Optional grayscale: grayscale JPEGs are much smaller than color ones, which suits text-only scans.",
        ],
    },
    "doc.pdfsecurity": {
        "idea": "Encryption uses PDFKit's write options; decryption requires verifying the password first.",
        "how": [
            "Encrypt: set <code>userPasswordOption</code> and <code>ownerPasswordOption</code>, and combine the permission bits from the raw bitmask of <code>PDFAccessPermissions</code>.",
            "Decrypt: verify with <code>unlock(withPassword:)</code>, then save a copy.",
        ],
        "notes": [
            "PDFKit always uses AES-256; the \"encryption strength\" option in the UI is informational only.",
            "Permission bits have to be combined as raw <code>UInt</code> \u2014 Swift bridges that enum as an Optional, so calling <code>formUnion</code> directly won't compile.",
        ],
    },
    "doc.ocr": {
        "idea": "Use Vision's text recognition; it can output plain text, Markdown or a <b>searchable PDF</b>.",
        "how": [
            "Rasterize the PDF into a sequence of images at the chosen DPI.",
            "Run <code>VNRecognizeTextRequest</code> on each image.",
            "Searchable PDF: draw the original image, then overlay the recognized text as <b>transparent text</b> at the matching positions \u2014 Vision returns normalized coordinates (bottom-left origin), which line up with the PDF coordinate system, so they can be used as-is.",
        ],
    },
    "archive.create": {
        "idea": "Split archives rely on 7z's <code>-v</code> flag, and encryption uses <code>-p</code> together with <code>-mhe=on</code> to encrypt file names as well.",
        "how": [
            "Pick the flags by format: <code>-tzip</code> for ZIP, <code>-t7z</code> for 7z.",
            "Splitting: pass a preset size directly (e.g. <code>-v100m</code>); to split by count, estimate the total size first and divide it by the number of parts to get the size of each.",
            "Encryption: <code>-p</code> followed by the password; for 7z, add <code>-mhe=on</code> to encrypt file names too.",
            "Compression level: <code>-mx=0\u20269</code>.",
        ],
        "notes": [
            "When splitting by count, estimate the compressed size at 75% \u2014 the actual ratio depends on the content and can't be known in advance.",
            "\"Store only, no compression\" (level 0) suits files that are already compressed and is much faster.",
        ],
    },
    "archive.extract": {
        "idea": "When extracting, the folder name has to lose every archive suffix, otherwise <code>movie.7z.001</code> ends up in a folder called <code>movie.7z</code>.",
        "how": [
            "Strip compound suffixes (<code>.tar.gz</code> and the like).",
            "Strip numeric volume suffixes (<code>.001</code>, <code>.part1</code>).",
            "Strip the single archive suffix (<code>.7z</code>, <code>.zip</code>).",
            "Use <code>-aos</code> to skip existing files, or <code>-aoa</code> to overwrite them.",
        ],
        "notes": [
            "7z's error message for a wrong password isn't very informative, so we check whether the output contains the word password and give a clear message like \"wrong password, or this archive is encrypted\".",
        ],
    },
    "utility.hash": {
        "idea": "One read produces five checksums, so the user doesn't have to pick an algorithm first. See \"Computing five checksums in a single pass\" for details.",
        "how": [
            "Stream the file in 1 MB chunks.",
            "Feed each chunk to MD5, SHA-1, SHA-256, SHA-512 and our own CRC32 implementation at the same time.",
            "Every result line has a copy button.",
            "Paste an expected value to compare against; the UI marks a match with \u2713 and a mismatch with \u2717.",
        ],
    },
    "utility.info": {
        "idea": "Which image fields get shown depends on the <b>file type</b> \u2014 an image has no duration or frame rate.",
        "how": [
            "Determine the type from the extension first, and only fall back to ffprobe stream detection when the container is unclear.",
            "Collect the data in five groups: file, dimensions and resolution, color, capture parameters, location.",
            "The dimensions group includes print size: pixel count \u00f7 DPI converted to inches and centimeters.",
            "Extract 6 representative colors for the dominant palette using median cut quantization.",
        ],
        "notes": [
            "In practice a single JPEG yields 5 groups and 19+ fields, with no duration, frame rate or bitrate among them.",
        ],
    },
    "archive.info": {
        "idea": "Use <code>7z l -slt</code> to get a structured key/value listing, then parse out each entry's path, original size and compressed size.",
        "how": [
            "Run <code>7z l -slt</code> and parse by prefixes such as <code>Path = </code>.",
            "Total up the entry count, original size and compressed size, then compute the savings ratio.",
            "Show at most 300 entries in the content list; beyond that, report the total count.",
        ],
    },
}

CJK = re.compile(r"[\u3000-\u303f\u3400-\u4dbf\u4e00-\u9fff\uff00-\uffef]")


def build(src, trans, path="$"):
    if isinstance(src, dict):
        assert isinstance(trans, dict), f"type mismatch at {path}"
        assert set(src) == set(trans), f"key mismatch at {path}: {set(src) ^ set(trans)}"
        return {k: build(src[k], trans[k], f"{path}.{k}") for k in src}
    if isinstance(src, list):
        assert isinstance(trans, list), f"type mismatch at {path}"
        assert len(src) == len(trans), f"length mismatch at {path}: {len(src)} vs {len(trans)}"
        return [build(s, t, f"{path}[{i}]") for i, (s, t) in enumerate(zip(src, trans))]
    assert isinstance(src, str) and isinstance(trans, str), f"leaf type mismatch at {path}"
    return trans


def tags(s):
    return (
        len(re.findall(r"<b>", s)),
        len(re.findall(r"</b>", s)),
        len(re.findall(r"<code>", s)),
        len(re.findall(r"</code>", s)),
    )


def count_tags(obj, acc):
    if isinstance(obj, dict):
        for v in obj.values():
            count_tags(v, acc)
    elif isinstance(obj, list):
        for v in obj:
            count_tags(v, acc)
    elif isinstance(obj, str):
        t = tags(obj)
        for i, n in enumerate(t):
            acc[i] += n


def code_contents(obj, acc):
    if isinstance(obj, dict):
        for v in obj.values():
            code_contents(v, acc)
    elif isinstance(obj, list):
        for v in obj:
            code_contents(v, acc)
    elif isinstance(obj, str):
        acc.extend(re.findall(r"<code>(.*?)</code>", obj, re.S))


def main():
    with open(SRC, encoding="utf-8") as f:
        src = json.load(f)
    out = build(src, TRANS)
    with open(DST, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
        f.write("\n")

    # --- verification -----------------------------------------------------
    with open(DST, encoding="utf-8") as f:
        reloaded = json.load(f)

    problems = []
    if set(reloaded) != set(src):
        problems.append("key set differs")
    for k in src:
        if list(reloaded[k]) != list(src[k]):
            problems.append(f"{k}: sub-key set/order differs")
        for sub in src[k]:
            if isinstance(src[k][sub], list) and len(reloaded[k][sub]) != len(src[k][sub]):
                problems.append(f"{k}.{sub}: list length differs")

    src_t, dst_t = [0, 0, 0, 0], [0, 0, 0, 0]
    count_tags(src, src_t)
    count_tags(reloaded, dst_t)
    if src_t != dst_t:
        problems.append(f"tag counts differ: {src_t} vs {dst_t}")

    leftovers = []
    for k, v in reloaded.items():
        for sub, val in v.items():
            vals = val if isinstance(val, list) else [val]
            for i, s in enumerate(vals):
                if CJK.search(s):
                    leftovers.append(f"{k}.{sub}[{i}]: {s}")

    src_code, dst_code = [], []
    code_contents(src, src_code)
    code_contents(reloaded, dst_code)
    # Identical except where the SOURCE had Chinese inside <code> (e.g. "-p密码"),
    # which must be de-sinicized to satisfy the no-Chinese-left rule.
    src_code_de_cjk = [CJK.sub("", s) for s in src_code]
    code_ok = src_code_de_cjk == dst_code
    deviations = [(a, b) for a, b in zip(src_code, dst_code) if a != b]
    if not code_ok:
        problems.append(f"<code> contents differ: {src_code_de_cjk} vs {dst_code}")

    print(f"tool ids translated: {len(reloaded)}")
    print(f"tag counts (b open, b close, code open, code close): src={src_t} out={dst_t}")
    print(f"code spans compared: {len(src_code)} (all identical: {src_code == dst_code})")
    print(f"code spans identical after de-sinicizing source: {code_ok}")
    for a, b in deviations:
        print(f"  DELIBERATE: <code>{a}</code> -> <code>{b}</code>")
    print(f"Chinese characters remaining: {len(leftovers)}")
    for x in leftovers:
        print("  LEFT:", x)
    if problems:
        print("PROBLEMS:")
        for p in problems:
            print("  -", p)
        sys.exit(1)
    print("ALL CHECKS PASSED")


if __name__ == "__main__":
    main()
