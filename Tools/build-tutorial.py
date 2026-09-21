#!/usr/bin/env python3
"""Generate the FormatForge HTML tutorial from the real source tree.

Nothing here is hand-written prose about the code: every tool, parameter,
preset and source listing is read from the project itself, so the document
cannot drift away from the implementation.
"""

import html
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs"
SRC = ROOT / "Sources"
REGISTRY = ROOT / "build" / "registry.json"

#: Languages the tutorial ships in. English is the default; the page embeds all
#: of them and switches client-side, so one HTML file serves every language.
LANGUAGES = ["en", "zh-Hans", "ja", "ko", "fr"]
DEFAULT_LANGUAGE = "en"

#: Language code -> name shown in the picker, written in that language so the
#: reader can find their own even when the page is in one they cannot read.
LABELS = {
    "en": "English",
    "zh-Hans": "简体中文",
    "ja": "日本語",
    "ko": "한국어",
    "fr": "Français",
}

#: Prose for the language currently being rendered.
T = {}

#: Every language's table, loaded once. The page carries all of them at the same
#: time and switches client-side, so the source excerpts — the bulk of the
#: document — are emitted only once instead of once per language.
TABLES = {}

#: Article index (id, title, blurb, files) for the active language.
ARTICLES = []


def language_path(code):
    return Path(__file__).resolve().parent / "tutorial" / "i18n" / f"{code}.json"


def load_language(code):
    """Load one language table, falling back to Chinese for anything missing."""
    path = language_path(code)
    if not path.exists():
        raise SystemExit(f"missing language table: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    return data


def t(path, default=""):
    """Look up a dotted path in the active table, e.g. t("chrome.nav.overview")."""
    node = T
    for part in path.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            return default
    return node if isinstance(node, str) else default


def article_content(article_id):
    """The deep-dive prose for one article."""
    return T.get("articles", {}).get(article_id, {})


def tool_note(tool_id):
    """The per-tool explanation, or None."""
    return T.get("toolNotes", {}).get(tool_id)


def file_note(rel_path):
    """The one-line description of a source file, or None."""
    return T.get("fileNotes", {}).get(rel_path)


def chrome(key, default=""):
    """An interface string, e.g. chrome("nav.overview").

    Looked up directly rather than through t(): chrome keys contain dots of
    their own ("page.title"), so a dotted-path walk would split them wrongly.
    """
    value = T.get("chrome", {}).get(key)
    return value if isinstance(value, str) else default


def block(block_id):
    """A block of static section HTML."""
    return T.get("blocks", {}).get(block_id, "")


#: Values the stored HTML blocks interpolate. Filled in by main() before any
#: block is rendered, so a template never has to guess at the caller's locals.
BLOCK_SCOPE = {}


def ml_values(values, escape=True):
    """Wrap one string per language in data-lang spans.

    The CSS shows only the span matching <html data-lang>, so switching language
    is instant and needs no server.
    """
    parts = []
    for code in LANGUAGES:
        text = values.get(code, "")
        if text == "":
            # Fall back to the default so a gap never renders as blank.
            text = values.get(DEFAULT_LANGUAGE, "")
        if escape:
            text = html.escape(text)
        parts.append(f'<span data-lang="{code}">{text}</span>')
    return "".join(parts)


def ml_field(value, escape=True):
    """Wrap a registry field — a {language: string} map — in data-lang spans.

    The registry dump emits every translatable string once per language, so the
    tool cards follow the page's language switch like everything else.
    """
    if isinstance(value, str):
        return html.escape(value) if escape else value
    if not isinstance(value, dict):
        return html.escape(str(value)) if escape else str(value)
    # Only the languages the tutorial ships are emitted; the rest would bloat
    # the page for no benefit.
    return ml_values({code: value.get(code, "") for code in LANGUAGES}, escape=escape)


def ml_chrome(key, escape=True, quote=False, **fmt):
    """Every language's text for a chrome key, as data-lang spans.

    `quote=True` is for HTML attributes. An attribute value cannot contain
    markup, so a span set there would be shown to the user as literal text;
    attributes therefore take the default language's plain string.
    """
    values = {}
    for code in LANGUAGES:
        text = TABLES.get(code, {}).get("chrome", {}).get(key, "")
        if fmt and text:
            try:
                text = text.format(**fmt)
            except (KeyError, IndexError):
                pass
        values[code] = text
    if quote:
        return html.escape(values.get(DEFAULT_LANGUAGE, ""), quote=True)
    return ml_values(values, escape=escape)


def ml_article(aid):
    """One article's prose merged across languages, with spans on each leaf."""
    merged = {}
    for code in LANGUAGES:
        pass  # presence check only; structure comes from the default table

    base = TABLES[DEFAULT_LANGUAGE]["articles"].get(aid, {})
    for key in ["principle"]:
        if key in base:
            merged[key] = ml_values(
                {c: TABLES[c]["articles"][aid].get(key, "") for c in LANGUAGES})
    for key in ["why", "steps", "pitfalls", "diagrams", "reading"]:
        if key not in base:
            continue
        rows = []
        for i in range(len(base[key])):
            arity = len(base[key][i])
            rows.append(tuple(
                ml_values({c: TABLES[c]["articles"][aid][key][i][j] for c in LANGUAGES})
                for j in range(arity)))
        merged[key] = rows
    return merged


def ml_article_index():
    """The article index merged across languages."""
    out = []
    for aid in TABLES[DEFAULT_LANGUAGE]["articleIndex"]:
        entry = TABLES[DEFAULT_LANGUAGE]["articleIndex"][aid]
        out.append((
            aid,
            ml_values({c: TABLES[c]["articleIndex"][aid]["title"] for c in LANGUAGES}),
            ml_values({c: TABLES[c]["articleIndex"][aid]["blurb"] for c in LANGUAGES}),
            entry["files"],
        ))
    return out


def ml_tool_note(tool_id):
    """A tool note merged across languages."""
    base = TABLES[DEFAULT_LANGUAGE]["toolNotes"].get(tool_id)
    if not base:
        return None
    merged = {"idea": ml_values({c: TABLES[c]["toolNotes"][tool_id].get("idea", "")
                                 for c in LANGUAGES})}
    merged["how"] = [
        ml_values({c: TABLES[c]["toolNotes"][tool_id]["how"][i] for c in LANGUAGES})
        for i in range(len(base["how"]))
    ]
    if base.get("notes"):
        merged["notes"] = [
            ml_values({c: TABLES[c]["toolNotes"][tool_id]["notes"][i] for c in LANGUAGES})
            for i in range(len(base["notes"]))
        ]
    return merged


def ml_file_note(rel_path):
    """A file note merged across languages, or None."""
    values = {c: TABLES[c].get("fileNotes", {}).get(rel_path, "") for c in LANGUAGES}
    if not any(values.values()):
        return None
    return ml_values(values)


def ml_block(block_id, scope=None):
    """A static HTML block, with each language's content inside one wrapper.

    A block is usually a single <section>, but the dependency notes also carry a
    separate testing section. Each top-level element is therefore emitted once
    (so its id stays unique) with a div[data-lang] per language holding that
    language's content.
    """
    per_language = {}
    for code in LANGUAGES:
        template = TABLES[code].get("blocks", {}).get(block_id, "")
        if not template:
            template = TABLES[DEFAULT_LANGUAGE].get("blocks", {}).get(block_id, "")

        values = dict(BLOCK_SCOPE)
        values.update(scope or {})

        # Blocks call html.escape(t["name"]) to join tool names. The registry
        # returns a per-language map, so escape() renders spans instead.
        class _HtmlShim:
            escape = staticmethod(lambda value: ml_field(value, escape=False))
            __getattr__ = staticmethod(lambda name: getattr(html, name))

        namespace = {"__builtins__": {}, "html": _HtmlShim(), "len": len, "sum": sum,
                     "ml_field": ml_field, "ml_chrome": ml_chrome,
                     "chrome": lambda k, **kw: TABLES[code].get("chrome", {}).get(k, ""),
                     "t": t}
        namespace.update(values)
        try:
            per_language[code] = eval(f'f"""{template}"""', namespace, namespace)  # noqa: S307
        except Exception as error:  # noqa: BLE001
            raise SystemExit(f"block {block_id!r} failed for {code}: {error!r}")

    # Structure comes from the default language; only the content differs.
    base = per_language[DEFAULT_LANGUAGE]
    pieces = _split_top_level(base)
    if not pieces:
        return "".join(f'<div data-lang="{c}">{per_language[c]}</div>' for c in LANGUAGES)

    out = []
    for index, (whole, _) in enumerate(pieces):
        # The opening tag of the base element, with everything before its
        # content; the language divs replace that content.
        opening = re.match(r'\s*<\w+[^>]*>', whole)
        closing = re.search(r'</\w+>\s*$', whole)
        if not opening:
            continue
        inner = []
        for code in LANGUAGES:
            parts = _split_top_level(per_language[code])
            body = parts[index][1] if index < len(parts) else ""
            inner.append(f'<div data-lang="{code}">{body}</div>')
        out.append(opening.group(0) + "".join(inner)
                   + (closing.group(0) if closing else ""))
    return "".join(out)


def _split_top_level(markup):
    """Split markup into its top-level elements as (opening, inner) pairs."""
    pieces = []
    i, n = 0, len(markup)
    while i < n:
        match = re.compile(r'<(\w+)[^>]*>').search(markup, i)
        if not match:
            break
        tag = match.group(1)
        depth, j = 1, match.end()
        pattern = re.compile(rf'</?{tag}\b[^>]*>')
        step = None
        while depth and j < n:
            step = pattern.search(markup, j)
            if not step:
                break
            depth += -1 if step.group(0).startswith("</") else 1
            j = step.end()
        if depth == 0 and step:
            pieces.append((markup[match.start():j], markup[match.end():step.start()]))
            i = j
        else:
            pieces.append((markup[match.start():], markup[match.end():]))
            break
    return pieces


def render_block(block_id, scope=None):
    """Render a stored HTML block, evaluating the expressions inside it.

    The blocks carry live values such as {len(tools)} and {total_lines:,}, so
    they are formatted against BLOCK_SCOPE rather than inserted as literal text.
    """
    template = block(block_id)
    if not template:
        return ""
    values = dict(BLOCK_SCOPE)
    values.update(scope or {})
    try:
        # Evaluated as an f-string so the expressions inside run, rather than
        # being treated as format keys — the blocks contain generator
        # expressions such as {", ".join(...) for t in tools}.
        #
        # The same dict is passed as globals *and* locals: a comprehension or
        # generator expression resolves names in the enclosing scope's globals,
        # so a separate locals mapping would hide html/len from it.
        namespace = {"__builtins__": {}, "html": html, "len": len, "sum": sum,
                     "t": t, "chrome": chrome}
        namespace.update(values)
        return eval(f'f"""{template}"""', namespace, namespace)  # noqa: S307
    except Exception as error:  # noqa: BLE001
        raise SystemExit(f"block {block_id!r} failed to render: {error!r}")

# ---------------------------------------------------------------- source model



# ---------------------------------------------------------------- helpers


def read(path):
    return (SRC / path).read_text(encoding="utf-8")


def doc_comment(text):
    """First meaningful //-comment block at the top of a file."""
    lines = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("//"):
            body = stripped.lstrip("/").strip()
            if body and not body.startswith("MARK"):
                lines.append(body)
        elif stripped == "" and not lines:
            continue
        elif lines:
            break
    return " ".join(lines[:3])


def swift_highlight(code):
    """Single-pass Swift tokenizer producing coloured HTML.

    A sequential regex approach is tempting but wrong: wrapping tokens inserts
    markup that later passes then re-match (a placeholder digit got picked up by
    the number rule, leaving unbalanced tags). So this scans once, left to
    right, and never looks at text it has already emitted.
    """
    KEYWORDS = {
        "actor", "associatedtype", "async", "await", "break", "case", "catch",
        "class", "continue", "default", "defer", "deinit", "do", "else", "enum",
        "extension", "fallthrough", "false", "fileprivate", "for", "func",
        "guard", "if", "import", "in", "init", "inout", "internal", "is", "let",
        "nil", "operator", "private", "protocol", "public", "repeat", "rethrows",
        "return", "self", "static", "struct", "subscript", "super", "switch",
        "throw", "throws", "true", "try", "typealias", "var", "where", "while",
        "some", "any", "nonisolated", "mutating", "convenience", "required",
        "weak", "unowned", "lazy", "indirect", "case", "in", "as", "willSet",
        "didSet", "get", "set", "final", "open", "override",
    }

    out = []
    i = 0
    n = len(code)

    def emit(kind, text):
        out.append(f'<span class="{kind}">{html.escape(text)}</span>')

    while i < n:
        ch = code[i]

        # Line comment.
        if code.startswith("//", i):
            j = code.find("\n", i)
            j = n if j == -1 else j
            emit("c-comment", code[i:j])
            i = j
            continue

        # Block comment (supports nesting, as Swift does).
        if code.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if code.startswith("/*", j):
                    depth += 1; j += 2
                elif code.startswith("*/", j):
                    depth -= 1; j += 2
                else:
                    j += 1
            emit("c-comment", code[i:j])
            i = j
            continue

        # String literals, including interpolation and raw strings.
        if ch == '"':
            j = i + 1
            while j < n:
                if code[j] == "\\":
                    j += 2; continue
                if code[j] == '"':
                    j += 1; break
                j += 1
            emit("c-string", code[i:j])
            i = j
            continue

        # Attributes.
        if ch == "@" and i + 1 < n and (code[i + 1].isalpha() or code[i + 1] == "_"):
            j = i + 1
            while j < n and (code[j].isalnum() or code[j] == "_"):
                j += 1
            emit("c-attr", code[i:j])
            i = j
            continue

        # Numbers.
        if ch.isdigit():
            j = i
            while j < n and (code[j].isdigit() or code[j] in "._"):
                j += 1
            emit("c-number", code[i:j])
            i = j
            continue

        # Identifiers: keywords, types, or plain text.
        if ch.isalpha() or ch == "_":
            j = i
            while j < n and (code[j].isalnum() or code[j] == "_"):
                j += 1
            word = code[i:j]
            if word in KEYWORDS:
                emit("c-keyword", word)
            elif word[0].isupper():
                emit("c-type", word)
            else:
                out.append(html.escape(word))
            i = j
            continue

        # Everything else is punctuation / whitespace.
        out.append(html.escape(ch))
        i += 1

    return "".join(out)


def bash_highlight(code):
    """Single-pass shell tokenizer.

    Same lesson as the Swift highlighter: running several regex passes over
    already-escaped-and-marked-up text lets a later rule match inside the markup
    that an earlier rule inserted.
    """
    KEYWORDS = {
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while",
        "until", "case", "esac", "function", "return", "local", "export", "set",
        "echo", "cd", "exit", "shift", "read", "source", "printf", "test",
    }
    out = []
    i, n = 0, len(code)

    def emit(kind, text):
        out.append(f'<span class="{kind}">{html.escape(text)}</span>')

    while i < n:
        ch = code[i]

        # Comment to end of line.
        if ch == "#":
            j = code.find("\n", i)
            j = n if j == -1 else j
            emit("c-comment", code[i:j])
            i = j
            continue

        # Quoted strings.
        if ch in "\"'":
            quote = ch
            j = i + 1
            while j < n and code[j] != quote:
                if code[j] == "\\":
                    j += 1
                j += 1
            j = min(j + 1, n)
            emit("c-string", code[i:j])
            i = j
            continue

        # Words.
        if ch.isalnum() or ch in "_-./":
            j = i
            while j < n and (code[j].isalnum() or code[j] in "_-./"):
                j += 1
            word = code[i:j]
            if word in KEYWORDS:
                emit("c-keyword", word)
            else:
                out.append(html.escape(word))
            i = j
            continue

        out.append(html.escape(ch))
        i += 1

    return "".join(out)


def code_block(code, language="swift", title=None, collapse_after=None, title_is_html=False):
    """Render a macOS-style code window.

    The collapse is a CSS max-height on the scroll container, so the highlighted
    markup is never rewritten — an earlier implementation rebuilt the <pre> from
    textContent and lost every colour until the user expanded it.
    """
    if language == "swift":
        body = swift_highlight(code)
    elif language in ("bash", "sh"):
        body = bash_highlight(code)
    else:
        body = html.escape(code)

    line_count = code.count("\n") + 1
    collapsible = bool(collapse_after) and line_count > collapse_after

    classes = "code-block" + (" collapsible" if collapsible else "")
    attrs = f' data-lines="{line_count}"'

    # Window chrome: three traffic lights, the file name, a line count and a
    # copy button.
    # `title` is usually a file name and needs escaping, but a multi-language
    # title arrives already rendered as spans and must be inserted as-is.
    if title:
        name = title if title_is_html else html.escape(title)
    else:
        name = html.escape(language)
    bar = (
        '<div class="code-bar">'
        '<span class="lights"><i></i><i></i><i></i></span>'
        f'<span class="code-name">{name}</span>'
        f'<span class="code-lines">{line_count}{ml_chrome("code.lineSuffix")}</span>'
        '<button class="copy-btn" type="button" '
        f'title="{ml_chrome("code.copyAll", quote=True)}">{ml_chrome("code.copy")}</button>'
        "</div>"
    )

    fade = '<div class="code-fade"></div>' if collapsible else ""
    button = (
        f'<button class="expand-btn" type="button">{ml_chrome("code.expand")}{line_count}{ml_chrome("code.linesSuffix")}</button>'
        if collapsible else ""
    )

    return (
        f'<div class="{classes}"{attrs}>'
        f"{bar}"
        f'<div class="code-body"><div class="code-scroll">'
        f'<pre class="code {language}"><code>{body}</code></pre>'
        f"</div>{fade}</div>"
        f"{button}"
        "</div>"
    )


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


# ---------------------------------------------------------------- page shell

CSS = """
/* ============================================================================
   Themes. Every palette is defined as a variable set on <html data-theme>;
   contrast was checked against WCAG AA (4.5:1 body, 3:1 large). The previous
   single dark theme failed on sidebar labels (3.84:1) and code comments
   (4.16:1), which is why they were hard to read.
   ========================================================================= */
:root{
  --r:12px; --r-sm:8px; --r-xs:6px;
  --mono:ui-monospace,"SF Mono",SFMono-Regular,"JetBrains Mono",Menlo,Consolas,monospace;
  --sans:-apple-system,BlinkMacSystemFont,"SF Pro SC","PingFang SC","Helvetica Neue",Inter,Arial,sans-serif;
  --font-scale:1;
}

/* ---------- Dark (default) ---------- */
/* ---------- language picker ---------- */
.lang-ctl select{
  font:inherit;font-size:12.5px;color:var(--fg-dim);
  background:var(--bg-card);border:1px solid var(--line);
  border-radius:7px;padding:3px 8px;cursor:pointer;max-width:130px;
}
.lang-ctl select:hover{color:var(--fg);border-color:var(--fg-mute)}

/* ---------- language switching ----------
   Every translated unit is emitted once per language as a span[data-lang]. Only
   the active language is displayed, so switching is instant and needs no
   server. Without JS, the default language stays visible. */
/* :not(html) matters — the root element carries data-lang too, and a bare
   [data-lang] rule would hide the whole page. */
[data-lang]:not(html){display:none}
html[data-lang="en"] [data-lang="en"],
html[data-lang="zh-Hans"] [data-lang="zh-Hans"],
html[data-lang="ja"] [data-lang="ja"],
html[data-lang="ko"] [data-lang="ko"],
html[data-lang="fr"] [data-lang="fr"]{display:inline}
/* A block's content sits in div[data-lang]; the div rule below shows the
   active one. Blocks are emitted with a single outer element so their ids stay
   unique. */
/* A list item or table row containing spans must not collapse to inline. */
li[data-lang],tr[data-lang],div[data-lang],p/* :not(html) matters — the root element carries data-lang too, and a bare
   [data-lang] rule would hide the whole page. */
[data-lang]:not(html){display:none}
html[data-lang="en"] li[data-lang="en"],html[data-lang="en"] tr[data-lang="en"],
html[data-lang="en"] div[data-lang="en"],html[data-lang="en"] p[data-lang="en"],
html[data-lang="zh-Hans"] li[data-lang="zh-Hans"],html[data-lang="zh-Hans"] tr[data-lang="zh-Hans"],
html[data-lang="zh-Hans"] div[data-lang="zh-Hans"],html[data-lang="zh-Hans"] p[data-lang="zh-Hans"],
html[data-lang="ja"] li[data-lang="ja"],html[data-lang="ja"] tr[data-lang="ja"],
html[data-lang="ja"] div[data-lang="ja"],html[data-lang="ja"] p[data-lang="ja"],
html[data-lang="ko"] li[data-lang="ko"],html[data-lang="ko"] tr[data-lang="ko"],
html[data-lang="ko"] div[data-lang="ko"],html[data-lang="ko"] p[data-lang="ko"],
html[data-lang="fr"] li[data-lang="fr"],html[data-lang="fr"] tr[data-lang="fr"],
html[data-lang="fr"] div[data-lang="fr"],html[data-lang="fr"] p[data-lang="fr"]{display:block}

html[data-theme="dark"]{
  --bg:#11141a; --bg-elev:#161a22; --bg-card:#1c212b; --bg-hover:#232936;
  --code-bg:#141922; --code-bar:#1e242f;
  --line:#2b3240; --line-soft:#232936;
  --fg:#eef2f8; --fg-dim:#b6c0cf; --fg-mute:#8b95a5;
  --accent:#6aa8ff; --accent-dim:#6aa8ff1f; --accent-line:#6aa8ff55;
  --green:#5ddb8f; --yellow:#f5c451; --red:#ff8080;
  --purple:#b79cff; --cyan:#4ad4e8; --orange:#ffa662; --pink:#ff8fc0;
  --c-keyword:#ff8fae; --c-type:#8fd0ff; --c-string:#9fe0a8;
  --c-comment:#8b95a5; --c-number:#ffbe7a; --c-attr:#cfa8ff;
  --c-plain:#dbe3ee;
  --shadow:0 1px 2px #00000045,0 6px 18px #00000028;
}
/* ---------- Dim: lower contrast, easier at night ---------- */
html[data-theme="dim"]{
  --bg:#1b1d22; --bg-elev:#212429; --bg-card:#272b32; --bg-hover:#2f343d;
  --code-bg:#1f2228; --code-bar:#2a2e36;
  --line:#3a3f48; --line-soft:#31353d;
  --fg:#e4e8ef; --fg-dim:#b8c0cb; --fg-mute:#98a2b0;
  --accent:#7fb0f5; --accent-dim:#7fb0f51f; --accent-line:#7fb0f555;
  --green:#7fc99b; --yellow:#dcc07a; --red:#e88b8b;
  --purple:#a99be0; --cyan:#78c2cf; --orange:#dfa077; --pink:#e59ab8;
  --c-keyword:#e39ab2; --c-type:#9dc4e8; --c-string:#a6cbaa;
  --c-comment:#a3adba; --c-number:#e8c194; --c-attr:#cbb6ea;
  --c-plain:#d2d7de;
  --shadow:0 1px 2px #00000030,0 6px 18px #0000001c;
}
/* ---------- Light ---------- */
html[data-theme="light"]{
  --bg:#ffffff; --bg-elev:#f7f8fa; --bg-card:#f4f6f9; --bg-hover:#eaeef4;
  --code-bg:#f8fafc; --code-bar:#eef1f6;
  --line:#d8dee7; --line-soft:#e6eaf0;
  --fg:#1c2128; --fg-dim:#434d5b; --fg-mute:#5a6472;
  --accent:#1f6feb; --accent-dim:#1f6feb14; --accent-line:#1f6feb44;
  --green:#1a7f37; --yellow:#9a6700; --red:#cf222e;
  --purple:#8250df; --cyan:#0d7d8c; --orange:#bc4c00; --pink:#bf3989;
  --c-keyword:#cf222e; --c-type:#0550ae; --c-string:#0a7d3f;
  --c-comment:#5c6570; --c-number:#8a3300; --c-attr:#6f3fc4;
  --c-plain:#1c2128;
  --shadow:0 1px 2px #1f23280f,0 6px 18px #1f23280d;
}
/* ---------- Sepia: warm paper ---------- */
html[data-theme="sepia"]{
  --bg:#f6f1e7; --bg-elev:#f0e9dc; --bg-card:#efe7d9; --bg-hover:#e6dcc9;
  --code-bg:#f3ece0; --code-bar:#e8dfcf;
  --line:#d9cdb8; --line-soft:#e3d8c6;
  --fg:#2e2519; --fg-dim:#514430; --fg-mute:#6a5c46;
  --accent:#8a5a1f; --accent-dim:#8a5a1f14; --accent-line:#8a5a1f44;
  --green:#3f6b32; --yellow:#8a6410; --red:#a33a2c;
  --purple:#6b4a8f; --cyan:#2a6b72; --orange:#a1541a; --pink:#94476e;
  --c-keyword:#a33a2c; --c-type:#2f5d8a; --c-string:#3f6b32;
  --c-comment:#6a5c46; --c-number:#7d4f12; --c-attr:#5c3d7d;
  --c-plain:#33291d;
  --shadow:0 1px 2px #33291d12,0 6px 18px #33291d0f;
}

*{box-sizing:border-box}
html{scroll-behavior:smooth;scroll-padding-top:88px}
body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--sans);
  font-size:calc(15px * var(--font-scale));
  line-height:1.78;-webkit-font-smoothing:antialiased;
  text-rendering:optimizeLegibility;transition:background .2s,color .2s}
a{color:var(--accent);text-decoration:none;transition:color .15s}
a:hover{filter:brightness(1.18);text-decoration:underline}
p code,li code,td code,th code,dd code{font-family:var(--mono);
  font-size:.87em;background:var(--bg-card);padding:.15em .42em;border-radius:5px;
  border:1px solid var(--line-soft);color:var(--c-plain);white-space:nowrap}
h1,h2,h3,h4{line-height:1.35;font-weight:650;letter-spacing:-.015em;color:var(--fg)}
h2{font-size:calc(25px * var(--font-scale));margin:66px 0 18px;padding-bottom:12px;
  border-bottom:1px solid var(--line)}
h3{font-size:calc(19px * var(--font-scale));margin:42px 0 14px}
h4{font-size:calc(15.5px * var(--font-scale));margin:30px 0 10px;
  color:var(--fg-dim);font-weight:600}
p{margin:14px 0}
ul,ol{margin:14px 0;padding-left:22px}
li{margin:6px 0}
li::marker{color:var(--fg-mute)}
hr{border:0;border-top:1px solid var(--line);margin:50px 0}
strong,b{color:var(--fg);font-weight:650}
em{color:var(--fg-dim)}

/* ---------- layout ---------- */
.layout{display:flex;min-height:100vh}
.sidebar{width:296px;flex:0 0 296px;background:var(--bg-elev);
  border-right:1px solid var(--line);position:sticky;top:0;height:100vh;
  display:flex;flex-direction:column;overflow:hidden}
.sidebar-scroll{flex:1;overflow-y:auto;overscroll-behavior:contain;padding-bottom:28px}
.sidebar-scroll::-webkit-scrollbar{width:9px}
.sidebar-scroll::-webkit-scrollbar-thumb{background:var(--line);border-radius:5px}
.sidebar-scroll::-webkit-scrollbar-track{background:transparent}
.main{flex:1;min-width:0;padding:0 56px 150px;max-width:1220px;margin:0 auto}
.brand{display:flex;align-items:center;gap:11px;padding:18px 20px 14px;
  border-bottom:1px solid var(--line);flex:0 0 auto}
.brand .mark{width:32px;height:32px;border-radius:9px;flex:0 0 32px;
  background:linear-gradient(140deg,var(--accent),var(--purple));
  display:grid;place-items:center;font-weight:800;font-size:13px;color:#fff;
  letter-spacing:-.02em}
.brand b{font-size:14.5px;display:block;letter-spacing:-.01em;color:var(--fg)}
.brand span{font-size:11.5px;color:var(--fg-mute)}

/* ---------- toolbar (theme + font size) ---------- */
.toolbar{display:flex;align-items:center;gap:8px;padding:10px 14px;
  border-bottom:1px solid var(--line);flex:0 0 auto;background:var(--bg-elev)}
.theme-dots{display:flex;gap:5px}
.theme-dots button{width:22px;height:22px;border-radius:50%;cursor:pointer;
  border:2px solid var(--line);padding:0;transition:transform .12s,border-color .12s}
.theme-dots button:hover{transform:scale(1.12)}
.theme-dots button[aria-pressed="true"]{border-color:var(--accent);
  box-shadow:0 0 0 2px var(--accent-dim)}
.theme-dots button[data-set="dark"]{background:#11141a}
.theme-dots button[data-set="dim"]{background:#272b32}
.theme-dots button[data-set="light"]{background:#ffffff}
.theme-dots button[data-set="sepia"]{background:#f0e9dc}
.font-ctl{margin-left:auto;display:flex;align-items:center;gap:2px}
.font-ctl button{width:24px;height:24px;border-radius:var(--r-xs);cursor:pointer;
  border:1px solid var(--line);background:transparent;color:var(--fg-dim);
  font-size:13px;font-weight:700;line-height:1;padding:0;transition:all .12s}
.font-ctl button:hover{background:var(--bg-hover);color:var(--fg)}
.font-ctl .lvl{font-size:10.5px;color:var(--fg-mute);font-family:var(--mono);
  min-width:30px;text-align:center}

.nav-search{margin:12px 14px 4px}
.nav-search input{width:100%;background:var(--bg);border:1px solid var(--line);
  color:var(--fg);border-radius:var(--r-sm);padding:9px 11px;
  font-size:calc(13px * var(--font-scale));font-family:var(--sans);outline:none;
  transition:border-color .15s,box-shadow .15s}
.nav-search input::placeholder{color:var(--fg-mute)}
.nav-search input:focus{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-dim)}
.nav-group{margin:16px 0 6px}
.nav-group>a{display:block;padding:8px 20px 5px;
  font-size:calc(11px * var(--font-scale));font-weight:700;
  letter-spacing:.07em;text-transform:uppercase;color:var(--fg-mute)}
.nav-group>a:hover{color:var(--fg-dim)}
.nav-item{display:flex;align-items:center;gap:8px;padding:7px 20px;
  font-size:calc(13.5px * var(--font-scale));color:var(--fg-dim);
  border-left:2px solid transparent;transition:all .12s}
.nav-item:hover{background:var(--bg-hover);color:var(--fg);text-decoration:none}
.nav-item.active{color:var(--accent);background:var(--accent-dim);
  border-left-color:var(--accent);font-weight:600}

/* ---------- hero ---------- */
.hero{padding:74px 0 30px;border-bottom:1px solid var(--line)}
.hero h1{font-size:calc(42px * var(--font-scale));margin:0 0 14px;letter-spacing:-.03em}
.hero .lede{font-size:calc(17px * var(--font-scale));color:var(--fg-dim);
  max-width:740px;margin:0;line-height:1.7}
.stats{display:flex;flex-wrap:wrap;gap:14px;margin:34px 0 10px}
.stat{background:var(--bg-card);border:1px solid var(--line);border-radius:var(--r);
  padding:16px 20px;min-width:126px;box-shadow:var(--shadow)}
.stat b{display:block;font-size:calc(24px * var(--font-scale));font-weight:700;
  letter-spacing:-.03em;color:var(--fg);line-height:1.2}
.stat span{font-size:calc(11px * var(--font-scale));color:var(--fg-mute);
  text-transform:uppercase;letter-spacing:.07em;font-weight:600}

/* ---------- cards ---------- */
.card{background:var(--bg-card);border:1px solid var(--line);border-radius:var(--r);
  padding:20px 22px;margin:18px 0;box-shadow:var(--shadow)}
.card.warn{border-color:var(--yellow);background:var(--bg-card)}
.card.ok{border-color:var(--green);background:var(--bg-card)}
.grid{display:grid;gap:16px}
.grid.two{grid-template-columns:repeat(auto-fit,minmax(300px,1fr))}

/* ---------- tables ---------- */
table{width:100%;border-collapse:separate;border-spacing:0;margin:18px 0;
  font-size:calc(13.5px * var(--font-scale));background:var(--bg-card);
  border:1px solid var(--line);border-radius:var(--r);overflow:hidden;
  box-shadow:var(--shadow)}
th,td{padding:11px 14px;text-align:left;border-bottom:1px solid var(--line-soft);
  vertical-align:top}
th{background:var(--bg-hover);font-weight:650;
  font-size:calc(11.5px * var(--font-scale));text-transform:uppercase;
  letter-spacing:.05em;color:var(--fg-mute)}
tr:last-child td{border-bottom:0}
tbody tr{transition:background .12s}
tbody tr:hover{background:var(--bg-hover)}

/* ---------- code window ---------- */
.code-block{position:relative;margin:20px 0;border:1px solid var(--line);
  border-radius:var(--r);background:var(--code-bg);overflow:hidden;
  box-shadow:var(--shadow)}
.code-bar{display:flex;align-items:center;gap:12px;padding:10px 14px;
  background:var(--code-bar);border-bottom:1px solid var(--line)}
.lights{display:flex;gap:7px;flex:0 0 auto}
.lights i{width:11px;height:11px;border-radius:50%;display:block}
.lights i:nth-child(1){background:#ff5f57}
.lights i:nth-child(2){background:#febc2e}
.lights i:nth-child(3){background:#28c840}
.code-name{font-family:var(--mono);font-size:calc(11.5px * var(--font-scale));
  color:var(--fg-dim);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
  min-width:0}
.code-lines{margin-left:auto;font-size:calc(10.5px * var(--font-scale));
  color:var(--fg-mute);font-family:var(--mono);flex:0 0 auto}
.copy-btn{flex:0 0 auto;font-family:var(--sans);
  font-size:calc(11.5px * var(--font-scale));font-weight:550;color:var(--fg-dim);
  background:transparent;border:1px solid var(--line);border-radius:var(--r-xs);
  padding:4px 11px;cursor:pointer;transition:all .15s;line-height:1.5}
.copy-btn:hover{background:var(--bg-hover);color:var(--fg);border-color:var(--accent)}
.copy-btn.done{color:var(--green);border-color:var(--green);background:transparent}
.code-body{position:relative}
.code-scroll{overflow:auto;max-height:none}
.code-scroll::-webkit-scrollbar{height:10px;width:10px}
.code-scroll::-webkit-scrollbar-thumb{background:var(--line);border-radius:5px}
.code-scroll::-webkit-scrollbar-track{background:transparent}
pre.code{margin:0;padding:16px 18px;font-family:var(--mono);
  font-size:calc(12.5px * var(--font-scale));line-height:1.7;tab-size:4;
  color:var(--c-plain);white-space:pre;
  -webkit-user-select:text;user-select:text}
pre.code code{background:none;border:0;padding:0;font-size:inherit;
  font-family:inherit;white-space:pre;color:inherit}
.code-block.collapsible:not(.is-open) .code-scroll{max-height:420px}
.code-fade{position:absolute;left:0;right:0;bottom:0;height:110px;
  background:linear-gradient(transparent,var(--code-bg) 78%);
  pointer-events:none;transition:opacity .2s}
.code-block.is-open .code-fade{opacity:0}
.expand-btn{display:block;width:100%;padding:11px;background:var(--code-bar);
  border:0;border-top:1px solid var(--line);color:var(--accent);cursor:pointer;
  font-size:calc(12.5px * var(--font-scale));font-weight:550;
  font-family:var(--sans);transition:background .15s}
.expand-btn:hover{background:var(--bg-hover)}
.c-keyword{color:var(--c-keyword)}
.c-type{color:var(--c-type)}
.c-string{color:var(--c-string)}
.c-comment{color:var(--c-comment);font-style:italic}
.c-number{color:var(--c-number)}
.c-attr{color:var(--c-attr)}

/* ---------- badges ---------- */
.badge{display:inline-flex;align-items:center;gap:4px;
  font-size:calc(11px * var(--font-scale));font-weight:600;padding:2.5px 8px;
  border-radius:999px;border:1px solid var(--line);white-space:nowrap;line-height:1.5;
  background:var(--bg-hover);color:var(--fg-dim)}
.b-video{color:var(--accent);border-color:var(--accent-line)}
.b-image{color:var(--pink);border-color:var(--pink)}
.b-document{color:var(--cyan);border-color:var(--cyan)}
.b-archive{color:var(--orange);border-color:var(--orange)}
.b-utility{color:var(--purple);border-color:var(--purple)}
.b-auto{color:var(--green);border-color:var(--green)}
.b-dep{color:var(--yellow);border-color:var(--yellow)}

/* ---------- tool cards ---------- */
.tool{border:1px solid var(--line);border-radius:var(--r);background:var(--bg-card);
  margin:22px 0;overflow:hidden;box-shadow:var(--shadow)}
.tool-head{display:flex;align-items:flex-start;gap:14px;padding:18px 22px;
  border-bottom:1px solid var(--line-soft)}
.tool-head .icon{width:36px;height:36px;border-radius:10px;flex:0 0 36px;
  display:grid;place-items:center;font-size:15px;background:var(--bg-hover);
  border:1px solid var(--line);font-family:var(--mono);color:var(--fg-dim);
  overflow:hidden;text-align:center;line-height:1}
.tool-head h3{margin:0 0 4px;font-size:calc(17px * var(--font-scale))}
.tool-head p{margin:0;font-size:calc(13px * var(--font-scale));
  color:var(--fg-dim);line-height:1.6}
.tool-body{padding:18px 22px}
.tool-id{font-family:var(--mono);font-size:calc(11px * var(--font-scale));
  color:var(--fg-mute)}
.meta{display:flex;flex-wrap:wrap;gap:7px;margin:0 0 14px}

/* ---------- explanation blocks ---------- */
.why{background:var(--bg-card);border:1px solid var(--line);
  border-left:3px solid var(--accent);border-radius:0 var(--r-sm) var(--r-sm) 0;
  padding:16px 20px;margin:18px 0}
.why>h5{margin:0 0 10px;font-size:calc(13px * var(--font-scale));font-weight:700;
  color:var(--accent);letter-spacing:.03em;text-transform:uppercase}
.why p{margin:10px 0}
.why ul,.why ol{margin:10px 0}
.why pre.code{margin:12px 0}
.pitfall{background:var(--bg-card);border:1px solid var(--yellow);
  border-left:3px solid var(--yellow);border-radius:0 var(--r-sm) var(--r-sm) 0;
  padding:16px 20px;margin:18px 0}
.pitfall>h5{margin:0 0 10px;font-size:calc(13px * var(--font-scale));
  font-weight:700;color:var(--yellow);letter-spacing:.03em;text-transform:uppercase}
.pitfall p:last-child{margin-bottom:0}
.analogy{background:var(--bg-card);border:1px solid var(--line);
  border-left:3px solid var(--purple);border-radius:0 var(--r-sm) var(--r-sm) 0;
  padding:16px 20px;margin:18px 0}
.analogy>h5{margin:0 0 10px;font-size:calc(13px * var(--font-scale));
  font-weight:700;color:var(--purple);letter-spacing:.03em;text-transform:uppercase}
.steps{counter-reset:step;list-style:none;padding-left:0;margin:18px 0}
.steps>li{counter-increment:step;position:relative;padding-left:44px;
  margin:16px 0;min-height:28px}
.steps>li::before{content:counter(step);position:absolute;left:0;top:1px;
  width:28px;height:28px;border-radius:50%;background:var(--accent-dim);
  border:1px solid var(--accent-line);color:var(--accent);
  display:grid;place-items:center;font-size:12.5px;font-weight:700;
  font-family:var(--mono)}
.steps>li>b{display:block;margin-bottom:3px}

/* ---------- diagrams ---------- */
.diagram{margin:22px 0;border:1px solid var(--line);border-radius:var(--r);
  background:var(--code-bg);overflow:hidden;box-shadow:var(--shadow)}
.diagram-title{padding:9px 16px;background:var(--code-bar);
  border-bottom:1px solid var(--line);font-size:calc(12px * var(--font-scale));
  color:var(--fg-dim);font-weight:600}
.diagram pre{margin:0;padding:18px;overflow-x:auto;
  font-family:var(--mono);font-size:calc(12px * var(--font-scale));
  line-height:1.55;color:var(--fg-dim);white-space:pre}
.diagram pre b{color:var(--accent);font-weight:600}
.diagram pre i{color:var(--green);font-style:normal}
.diagram pre u{color:var(--orange);text-decoration:none}
.diagram pre s{color:var(--purple);text-decoration:none}
figure{margin:22px 0}
figcaption{margin-top:8px;font-size:calc(12px * var(--font-scale));
  color:var(--fg-mute);text-align:center}

/* ---------- misc ---------- */
.note{border-left:3px solid var(--accent);background:var(--accent-dim);
  padding:14px 18px;border-radius:0 var(--r-sm) var(--r-sm) 0;margin:18px 0}
.note.warn{border-left-color:var(--yellow);background:transparent}
.note.ok{border-left-color:var(--green);background:transparent}
footer{margin-top:100px;padding-top:28px;border-top:1px solid var(--line);
  color:var(--fg-mute);font-size:calc(13px * var(--font-scale))}
.hidden{display:none!important}
.top-link{position:fixed;right:26px;bottom:26px;width:42px;height:42px;
  border-radius:50%;background:var(--bg-card);border:1px solid var(--line);
  display:grid;place-items:center;color:var(--fg-dim);font-size:16px;z-index:20;
  box-shadow:var(--shadow);transition:all .15s}
.top-link:hover{color:var(--fg);border-color:var(--accent);text-decoration:none;
  transform:translateY(-2px)}

@media (max-width:1040px){
  .sidebar{display:none}
  .main{padding:0 22px 90px}
  .hero h1{font-size:calc(31px * var(--font-scale))}
  .hero{padding:44px 0 22px}
}
"""

JS = """
/* Sidebar filtering, active-section tracking, CSS-based code collapsing and
   clipboard copying. No innerHTML rewriting: an earlier version rebuilt the
   collapsed <pre> from textContent, which silently discarded every syntax
   highlight span (colour only appeared after expanding). */
(function () {
  'use strict';

  /* ---------- sidebar filter ---------- */
  var filter = document.getElementById('navFilter');
  if (filter) {
    filter.addEventListener('input', function () {
      var q = this.value.trim().toLowerCase();
      document.querySelectorAll('.nav-item').forEach(function (el) {
        var hay = el.getAttribute('data-search') || el.textContent.toLowerCase();
        el.classList.toggle('hidden', q !== '' && hay.indexOf(q) === -1);
      });
      document.querySelectorAll('.nav-group').forEach(function (group) {
        var items = group.querySelectorAll('.nav-item');
        var any = Array.prototype.some.call(items, function (i) {
          return !i.classList.contains('hidden');
        });
        group.classList.toggle('hidden', items.length > 0 && !any);
      });
    });
    document.addEventListener('keydown', function (e) {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault();
        filter.focus();
        filter.select();
      }
      if (e.key === 'Escape' && document.activeElement === filter) {
        filter.value = '';
        filter.dispatchEvent(new Event('input'));
        filter.blur();
      }
    });
  }

  /* ---------- collapse / expand (CSS class only) ---------- */
  document.querySelectorAll('.code-block.collapsible').forEach(function (block) {
    var btn = block.querySelector('.expand-btn');
    if (!btn) return;
    var total = block.getAttribute('data-lines') || '';
    btn.addEventListener('click', function () {
      var open = block.classList.toggle('is-open');
      btn.textContent = open ? strings.collapse : (strings.expand + total + strings.lines);
    });
  });

  /* ---------- copy ---------- */
  function legacyCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0;pointer-events:none';
    document.body.appendChild(ta);
    ta.select();
    ta.setSelectionRange(0, text.length);
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (err) { ok = false; }
    document.body.removeChild(ta);
    return ok;
  }

  document.querySelectorAll('.copy-btn').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var block = btn.closest('.code-block');
      var code = block ? block.querySelector('pre.code code') : null;
      if (!code) return;
      var text = code.textContent;

      function flash(ok) {
        btn.textContent = ok ? strings.copied : strings.failed;
        btn.classList.toggle('done', ok);
        setTimeout(function () {
          btn.textContent = strings.copy;
          btn.classList.remove('done');
        }, 1500);
      }

      // The clipboard API needs a secure context; a local file:// page is not
      // one in every browser, so fall back to execCommand.
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(
          function () { flash(true); },
          function () { flash(legacyCopy(text)); }
        );
      } else {
        flash(legacyCopy(text));
      }
    });
  });

  /* ---------- language ---------- */
  var LANGS = ['en', 'zh-Hans', 'ja', 'ko', 'fr'];
  var LANG_LABELS = {
    'en': {copy: 'Copy', copied: 'Copied', failed: 'Copy failed',
           collapse: 'Collapse', expand: 'Expand all ', lines: ' lines'},
    'zh-Hans': {copy: '复制', copied: '已复制', failed: '复制失败',
           collapse: '收起代码', expand: '展开全部 ', lines: ' 行'},
    'ja': {copy: 'コピー', copied: 'コピーしました', failed: 'コピー失敗',
           collapse: '折りたたむ', expand: 'すべて展開 ', lines: ' 行'},
    'ko': {copy: '복사', copied: '복사됨', failed: '복사 실패',
           collapse: '접기', expand: '전체 펼치기 ', lines: '행'},
    'fr': {copy: 'Copier', copied: 'Copié', failed: 'Échec de la copie',
           collapse: 'Réduire', expand: 'Tout afficher ', lines: ' lignes'}
  };
  var strings = LANG_LABELS['en'];

  function applyLanguage(code) {
    if (LANGS.indexOf(code) === -1) code = 'en';
    root.setAttribute('data-lang', code);
    root.setAttribute('lang', code);
    strings = LANG_LABELS[code] || LANG_LABELS['en'];
    var pick = document.getElementById('langPick');
    if (pick) pick.value = code;
    // Refresh the labels the script itself injects.
    document.querySelectorAll('.copy-btn').forEach(function (b) {
      if (!b.classList.contains('done')) b.textContent = strings.copy;
    });
    document.querySelectorAll('.code-block.collapsible').forEach(function (block) {
      var btn = block.querySelector('.expand-btn');
      if (!btn) return;
      var total = block.getAttribute('data-lines') || '';
      btn.textContent = block.classList.contains('is-open')
        ? strings.collapse : (strings.expand + total + strings.lines);
    });
    try { localStorage.setItem('ff-lang', code); } catch (e) {}
  }

  /* ---------- theme + font size ---------- */
  var THEMES = ['dark', 'dim', 'light', 'sepia'];
  var SCALES = [0.9, 1, 1.1, 1.25, 1.4, 1.6];
  var root = document.documentElement;

  function applyTheme(name) {
    if (THEMES.indexOf(name) === -1) name = 'dark';
    root.setAttribute('data-theme', name);
    try { localStorage.setItem('ff-theme', name); } catch (e) {}
    document.querySelectorAll('.theme-dots button').forEach(function (b) {
      b.setAttribute('aria-pressed', String(b.getAttribute('data-set') === name));
    });
  }

  function applyScale(index) {
    index = Math.max(0, Math.min(SCALES.length - 1, index));
    root.style.setProperty('--font-scale', String(SCALES[index]));
    var label = document.getElementById('fontLevel');
    if (label) label.textContent = Math.round(SCALES[index] * 100) + '%';
    try { localStorage.setItem('ff-scale', String(index)); } catch (e) {}
  }

  document.querySelectorAll('.theme-dots button').forEach(function (b) {
    b.addEventListener('click', function () { applyTheme(b.getAttribute('data-set')); });
  });

  var langPick = document.getElementById('langPick');
  if (langPick) {
    langPick.addEventListener('change', function () { applyLanguage(this.value); });
  }

  var scaleIndex = 1;
  var minus = document.getElementById('fontMinus');
  var plus = document.getElementById('fontPlus');
  if (minus) minus.addEventListener('click', function () { applyScale(--scaleIndex); });
  if (plus) plus.addEventListener('click', function () { applyScale(++scaleIndex); });

  // Keyboard: T cycles themes, +/- adjusts text size.
  document.addEventListener('keydown', function (e) {
    if (e.target && /INPUT|TEXTAREA/.test(e.target.tagName)) return;
    if (e.key === 't' || e.key === 'T') {
      var now = root.getAttribute('data-theme') || 'dark';
      applyTheme(THEMES[(THEMES.indexOf(now) + 1) % THEMES.length]);
    }
    if (e.key === '=' || e.key === '+') { applyScale(++scaleIndex); }
    if (e.key === '-' || e.key === '_') { applyScale(--scaleIndex); }
    if (e.key === '0') { scaleIndex = 1; applyScale(1); }
  });

  // Restore saved preferences.
  var savedTheme = 'dark', savedScale = '1';
  try {
    savedTheme = localStorage.getItem('ff-theme') || 'dark';
    savedScale = localStorage.getItem('ff-scale') || '1';
  } catch (e) {}
  applyTheme(savedTheme);
  var savedLang = 'en';
  try { savedLang = localStorage.getItem('ff-lang') || 'en'; } catch (e) {}
  applyLanguage(savedLang);
  scaleIndex = parseInt(savedScale, 10);
  if (isNaN(scaleIndex) || scaleIndex < 0 || scaleIndex >= SCALES.length) scaleIndex = 1;
  applyScale(scaleIndex);

  /* ---------- active section ---------- */
  var links = Array.prototype.slice.call(
    document.querySelectorAll('.nav-item[href^="#"]'));
  var byId = {};
  links.forEach(function (l) { byId[l.getAttribute('href').slice(1)] = l; });

  if ('IntersectionObserver' in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        links.forEach(function (l) { l.classList.remove('active'); });
        var link = byId[entry.target.id];
        if (link) {
          link.classList.add('active');
          var box = link.closest('.sidebar-scroll');
          if (box) {
            var top = link.offsetTop, h = box.clientHeight;
            if (top < box.scrollTop + 60 || top > box.scrollTop + h - 60) {
              box.scrollTop = top - h / 2;
            }
          }
        }
      });
    }, { rootMargin: '-80px 0px -70% 0px', threshold: 0 });
    document.querySelectorAll('section[id]').forEach(function (s) {
      observer.observe(s);
    });
  }
})();
"""


def build_toolbar():
    """Theme swatches and text-size controls, pinned above the nav."""
    dots = "".join(
        f'<button type="button" data-set="{key}" aria-pressed="false" '
        f'title="{html.escape(label)}" aria-label="{html.escape(label)}"></button>'
        for key, label in [("dark", ml_chrome("theme.dark", quote=True)),
                           ("dim", ml_chrome("theme.dim", quote=True)),
                           ("light", ml_chrome("theme.light", quote=True)),
                           ("sepia", ml_chrome("theme.sepia", quote=True))]
    )
    lang_options = "".join(
        f'<option value="{code}"{" selected" if code == DEFAULT_LANGUAGE else ""}>'
        f'{html.escape(LABELS[code])}</option>'
        for code in LANGUAGES
    )
    picker = (f'<select id="langPick" aria-label="Language" title="Language">'
              f'{lang_options}</select>')
    return (
        '<div class="toolbar">'
        f'<div class="lang-ctl">{picker}</div>'
        f'<div class="theme-dots">{dots}</div>'
        '<div class="font-ctl">'
        f'<button type="button" id="fontMinus" title="{ml_chrome("toolbar.fontDown.help", quote=True)}" '
        f'aria-label="{ml_chrome("toolbar.fontDown", quote=True)}">A−</button>'
        '<span class="lvl" id="fontLevel">100%</span>'
        f'<button type="button" id="fontPlus" title="{ml_chrome("toolbar.fontUp.help", quote=True)}" '
        f'aria-label="{ml_chrome("toolbar.fontUp", quote=True)}">A+</button>'
        "</div>"
        "</div>"
    )


def build_nav(tools_by_cat, articles):
    parts = [
        '<div class="nav-search">'
        f'<input id="navFilter" type="search" placeholder="{ml_chrome("nav.filter.placeholder", quote=True)}" autocomplete="off">'
        "</div>"
    ]
    parts.append(f'<div class="nav-group"><a href="#top">{ml_chrome("nav.top")}</a>')
    for anchor, key in [("overview", "overview"), ("quickstart", "quickstart"),
                        ("architecture", "architecture")]:
        parts.append(f'<a class="nav-item" href="#{anchor}">{ml_chrome("nav." + key)}</a>')
    parts.append("</div>")

    parts.append(f'<div class="nav-group"><a href="#articles">{ml_chrome("nav.articles")}</a>')
    for aid, title, _, _ in articles:
        parts.append(f'<a class="nav-item" href="#{aid}">{title}</a>')
    parts.append("</div>")

    for cat_id, cat_title, tools in tools_by_cat:
        parts.append(f'<div class="nav-group"><a href="#cat-{cat_id}">{ml_field(cat_title)}'
                     f' ({len(tools)})</a>')
        for tool in tools:
            search = f"{tool['name']} {tool['id']} {tool['summary']}".lower()
            parts.append(
                f'<a class="nav-item" href="#tool-{tool["id"]}" '
                f'data-search="{html.escape(search, quote=True)}">'
                f'{ml_field(tool["name"])}</a>'
            )
        parts.append("</div>")

    parts.append(f'<div class="nav-group"><a href="#appendix">{ml_chrome("nav.appendix")}</a>')
    for anchor, key in [("source-tree", "source"), ("deps", "dependencies"),
                        ("testing", "testing")]:
        parts.append(f'<a class="nav-item" href="#{anchor}">{ml_chrome("nav." + key)}</a>')
    parts.append("</div>")
    return "\n".join(parts)


def render_parameters(tool):
    if not tool["parameters"]:
        return ml_chrome("param.noneHtml", escape=False)

    rows = []
    for p in tool["parameters"]:
        kind = p["kind"]
        extra = p.get("extra", {}) or {}
        if kind == "picker":
            options = extra.get("options", [])
            detail = "<br>".join(
                f'<code>{html.escape(o["id"])}</code> {html.escape(o["label"])}'
                + (f' — {html.escape(o["detail"])}' if o.get("detail") else "")
                for o in options
            )
        elif kind in ("number", "slider"):
            detail = ml_chrome("param.range", min=extra.get("min"), max=extra.get("max"), step=extra.get("step"))
        elif kind == "text":
            detail = ml_chrome("param.placeholder", value=f'<code>{html.escape(str(extra.get("placeholder", "")))}</code>')
        else:
            detail = ml_chrome("param.toggle")

        rows.append(
            "<tr>"
            f'<td><code>{html.escape(p["id"])}</code></td>'
            f'<td>{ml_field(p["label"])}</td>'
            f'<td>{html.escape(kind)}</td>'
            f'<td>{detail}</td>'
            f'<td><code>{html.escape(str(p["default"]))}</code></td>'
            f'<td>{ml_field(p["hint"])}</td>'
            "</tr>"
        )

    return (
        ml_chrome("table.headerRow", escape=False)
        + "".join(rows)
        + "</tbody></table>"
    )


def render_tool_explanation(tool_id):
    """Per-tool notes: the idea, the concrete steps, and any trade-offs."""
    note = ml_tool_note(tool_id)
    if not note:
        return ""

    parts = [f'<h4>{ml_chrome("section.howItWorks")}</h4>']
    if note.get("idea"):
        parts.append(f'<div class="note">{note["idea"]}</div>')

    if note.get("how"):
        parts.append('<ol class="steps">')
        for step in note["how"]:
            parts.append(f"<li>{step}</li>")
        parts.append("</ol>")

    if note.get("notes"):
        parts.append(f'<div class="analogy"><h5>{ml_chrome("section.notes")}</h5><ul>')
        for item in note["notes"]:
            parts.append(f"<li>{item}</li>")
        parts.append("</ul></div>")

    return "".join(parts)


def render_presets(tool):
    if not tool["presets"]:
        return ""
    cards = []
    for preset in tool["presets"]:
        values = preset.get("values") or {}
        if values:
            body = "<br>".join(
                f'<code>{html.escape(k)}</code> = <code>{html.escape(str(v))}</code>'
                for k, v in values.items()
            )
        else:
            body = ml_chrome("preset.manualHtml", escape=False)
        cards.append(
            '<div class="card" style="margin:0">'
            f'<b>{ml_field(preset["label"])}</b><br>'
            f'<span style="font-size:12.5px;color:var(--fg-dim)">'
            f'{ml_field(preset["detail"])}</span>'
            f'<div style="margin-top:8px;font-size:12px">{body}</div>'
            "</div>"
        )
    return (
        f'<h4>{ml_chrome("section.presets")}</h4><div class="grid two">' + "".join(cards) + "</div>"
    )


def tool_source_map():
    """Map tool id -> (file, start_line, end_line) by scanning for `id: "..."`."""
    index = {}
    for path in sorted(SRC.rglob("*.swift")):
        rel = str(path.relative_to(SRC))
        text = path.read_text(encoding="utf-8")
        lines = text.splitlines()
        for i, line in enumerate(lines):
            m = re.search(r'id:\s*"([a-z]+\.[a-z0-9]+)"', line)
            if not m:
                continue
            tool_id = m.group(1)
            if tool_id in index:
                continue
            # Walk backwards to the enclosing declaration.
            start = i
            while start > 0 and not re.search(r"(static let \w+|Tool\()", lines[start]):
                start -= 1
            # Walk forwards to the closing paren at the same indent.
            indent = len(lines[start]) - len(lines[start].lstrip())
            end = i
            depth = 0
            for j in range(start, len(lines)):
                depth += lines[j].count("(") - lines[j].count(")")
                if depth <= 0 and j > start:
                    end = j
                    break
            else:
                end = min(start + 60, len(lines) - 1)
            index[tool_id] = (rel, start + 1, end + 1)
    return index


def main():
    global T, ARTICLES

    # The tutorial embeds every language in one page and switches client-side,
    # so each table is loaded and rendered in turn.
    global TABLES
    # A language whose table is not translated yet falls back to the default,
    # so the page always builds and the missing one simply shows English.
    for code in LANGUAGES:
        try:
            TABLES[code] = load_language(code)
        except SystemExit:
            print(f"  ! no table for {code}; falling back to {DEFAULT_LANGUAGE}")
            TABLES[code] = load_language(DEFAULT_LANGUAGE)
    T = TABLES[DEFAULT_LANGUAGE]
    ARTICLES = ml_article_index()

    if not REGISTRY.exists():
        sys.exit(TABLES[DEFAULT_LANGUAGE]["chrome"].get("error.noRegistry", "missing build/registry.json"))
    registry = json.loads(REGISTRY.read_text(encoding="utf-8"))
    tools = registry["tools"]
    source_map = tool_source_map()

    categories = ["video", "image", "document", "archive", "utility"]
    cat_titles = {c["id"]: c["title"] for c in registry["categories"]}
    tools_by_cat = [
        (c, cat_titles.get(c, c), [t for t in tools if t["category"] == c])
        for c in categories
    ]

    OUT.mkdir(exist_ok=True)
    (OUT / "assets").mkdir(exist_ok=True)
    (OUT / "assets" / "style.css").write_text(CSS, encoding="utf-8")
    (OUT / "assets" / "app.js").write_text(JS, encoding="utf-8")

    # ---------------------------------------------------------- build sections
    body = []

    # Overview
    total_params = sum(len(t["parameters"]) for t in tools)
    total_presets = sum(len(t["presets"]) for t in tools)
    swift_files = sorted(SRC.rglob("*.swift"))
    total_lines = sum(len(p.read_text(encoding="utf-8").splitlines()) for p in swift_files)

    # Everything the stored HTML blocks interpolate. Kept in one place so a
    # template can never depend on the caller's local variable names.
    # Values the stored blocks interpolate. `html` is deliberately absent:
    # ml_block installs a shim whose escape() renders multi-language spans, and
    # a real html module here would silently override it.
    BLOCK_SCOPE.update({
        "len": len,
        "tools": tools,
        "swift_files": swift_files,
        "total_lines": total_lines,
        "total_params": total_params,
        "total_presets": total_presets,
        "sum": sum,
    })

    body.append(ml_block("overview", locals()))

    # Quick start
    body.append(ml_block("quickstart", locals()))
    body.append(code_block(
        TABLES[DEFAULT_LANGUAGE]["chrome"].get("code.buildCommands", ""),
        "bash", ml_chrome("code.buildCommands.title"), title_is_html=True))

    body.append(ml_block("dependencies", locals()))

    # Architecture
    body.append(ml_block("architecture", locals()))
    body.append(code_block(TABLES[DEFAULT_LANGUAGE]["chrome"].get("code.tree", ""),
                           "text", ml_chrome("code.treeStructure"), title_is_html=True))

    body.append(ml_block("dataflow", locals()))

    # Articles — principle, rationale, steps, pitfalls, diagrams, source.
    body.append(f'<section id="articles"><h2>{ml_chrome("nav.articles")}</h2>'
                f'<p>{ml_chrome("articles.intro", escape=False)}</p>')

    for aid, title, intro, files in ARTICLES:
        content = ml_article(aid)
        body.append(f'<section id="{aid}"><h3>{title}</h3>')
        if intro:
            body.append(f"<p>{intro}</p>")

        if content.get("principle"):
            body.append(f'<div class="note"><b>{ml_chrome("articles.principle")}</b>'
                        f'　{content["principle"]}</div>')

        # Why it is written this way.
        if content.get("why"):
            body.append(f'<h4>{ml_chrome("articles.why")}</h4>')
            for heading, text in content["why"]:
                body.append(
                    '<div class="why"><h5>' + heading + "</h5>"
                    f"<p>{text}</p></div>"
                )

        # Diagrams.
        if content.get("diagrams"):
            body.append(f'<h4>{ml_chrome("articles.diagrams")}</h4>')
            for dtitle, art in content["diagrams"]:
                body.append(
                    '<figure class="diagram">'
                    f'<div class="diagram-title">{dtitle}</div>'
                    f"<pre>{art}</pre>"
                    "</figure>"
                )

        # Ordered walkthrough.
        if content.get("steps"):
            body.append(f'<h4>{ml_chrome("articles.steps")}</h4><ol class="steps">')
            for stitle, stext in content["steps"]:
                body.append(f"<li><b>{stitle}</b>{stext}</li>")
            body.append("</ol>")

        # Real pitfalls.
        if content.get("pitfalls"):
            body.append(f'<h4>{ml_chrome("articles.pitfalls")}</h4>')
            for problem, cause, fix in content["pitfalls"]:
                body.append(
                    '<div class="pitfall">'
                    f'<h5>{problem}</h5>'
                    f'<p><b>{ml_chrome("articles.cause")}</b>{cause}</p>'
                    f'<p><b>{ml_chrome("articles.fix")}</b>{fix}</p>'
                    "</div>"
                )

        # Reading guide before the source listings.
        if content.get("reading"):
            body.append(f'<h4>{ml_chrome("articles.reading")}</h4><ul>')
            for rel, hint in content["reading"]:
                body.append(f'<li><code>{rel}</code> — {hint}</li>')
            body.append("</ul>")

        for rel in files:
            path = SRC / rel
            if not path.exists():
                continue
            code = path.read_text(encoding="utf-8")
            note = ml_file_note(rel) or html.escape(doc_comment(code))
            body.append(f"<h4><code>{html.escape(rel)}</code></h4>")
            if note:
                body.append(f"<p>{note}</p>")
            body.append(code_block(code, "swift", rel, collapse_after=90))
        body.append("</section>")
    body.append("</section>")

    # Tools
    body.append(f'<section id="tools"><h2>{ml_chrome("tools.heading")}</h2>'
                f'<p>{ml_chrome("tools.intro")}</p></section>')

    for cat_id, cat_title, cat_tools in tools_by_cat:
        if not cat_tools:
            continue
        body.append(f'<section id="cat-{cat_id}"><h3>{ml_field(cat_title)}'
                    f' ({len(cat_tools)})</h3></section>')
        for tool in cat_tools:
            badges = [f'<span class="badge b-{tool["category"]}">'
                      f'{ml_field(tool["categoryTitle"])}</span>']
            if tool["isInspection"]:
                badges.append(f'<span class="badge b-auto">{ml_chrome("badge.automatic")}</span>')
            if tool["resultKind"] == "inPlace":
                badges.append(f'<span class="badge b-muted">{ml_chrome("badge.inPlace")}</span>')
            if tool["requiresFFmpeg"]:
                badges.append(f'<span class="badge b-dep">{ml_chrome("badge.needsFFmpeg")}</span>')
            if tool["requiresSevenZip"]:
                badges.append(f'<span class="badge b-dep">{ml_chrome("badge.needs7z")}</span>')

            accepts = tool["accepts"]
            accepts_text = (ml_chrome("drop.anyFile") if not accepts
                            else "、".join(a.upper() for a in accepts[:14])
                                 + ("…" if len(accepts) > 14 else ""))

            parts = [
                f'<div class="tool" id="tool-{tool["id"]}">',
                '<div class="tool-head">',
                f'<div class="icon">{html.escape(tool["symbol"])}</div>',
                "<div>",
                f'<h3>{ml_field(tool["name"])}</h3>',
                f'<p>{ml_field(tool["summary"])}</p>',
                "</div></div>",
                '<div class="tool-body">',
                f'<div class="meta">{"".join(badges)}'
                f'<span class="badge b-muted">{html.escape(tool["id"])}</span></div>',
                "<table><tbody>",
                f'<tr><th style="width:120px">{ml_chrome("table.accepts")}</th><td>{accepts_text}</td></tr>',
                f'<tr><th>{ml_chrome("table.buttonLabel")}</th><td>{ml_field(tool["actionTitle"]) or ml_chrome("drop.automatic")}</td></tr>',
                f'<tr><th>{ml_chrome("table.minimumInputs")}</th>'
                f'<td>{tool["minimumInputs"]}{ml_chrome("table.filesSuffix")}'
                f'{" " + ml_chrome("drop.multiple") if tool["allowsMultiple"] else " " + ml_chrome("drop.single")}</td></tr>',
                "</tbody></table>",
                ml_chrome("section.parametersHtml", escape=False),
                render_parameters(tool),
                render_presets(tool),
                render_tool_explanation(tool["id"]),
            ]

            if tool["id"] in source_map:
                rel, start, end = source_map[tool["id"]]
                lines = (SRC / rel).read_text(encoding="utf-8").splitlines()
                snippet = "\n".join(lines[start - 1:end])
                parts.append(ml_chrome("section.sourceHtml", escape=False))
                parts.append(
                    f'<p class="tool-id">{ml_chrome(("source.lineRange").format(file=rel, start=start, end=end))}</p>'
                )
                parts.append(code_block(snippet, "swift", f"{rel}:{start}", collapse_after=70))

            parts.append("</div></div>")
            body.append("".join(parts))

    # Appendix
    body.append(f'<section id="appendix"><h2>{ml_chrome("nav.appendix")}</h2></section>')

    body.append(f'<section id="source-tree"><h3>{ml_chrome("nav.source")}</h3>')
    body.append(ml_chrome("source.introHtml", escape=False))
    for path in swift_files:
        rel = str(path.relative_to(SRC))
        code = path.read_text(encoding="utf-8")
        note = ml_file_note(rel) or html.escape(doc_comment(code))
        body.append(f'<div class="tool" id="file-{slug(rel)}">'
                    f'<div class="tool-head"><div class="icon">📄</div><div>'
                    f'<h3><code>{html.escape(rel)}</code></h3>'
                    f'<p>{note}</p></div></div>'
                    f'<div class="tool-body">'
                    f'{code_block(code, "swift", ml_chrome("source.fileMeta", rel=rel, lines=len(code.splitlines())), collapse_after=120, title_is_html=True)}'
                    f"</div></div>")
    body.append("</section>")

    body.append(ml_block("deps", locals()))

    # ---------------------------------------------------------- assemble page
    nav = build_nav(tools_by_cat, ARTICLES)
    toolbar = build_toolbar()
    page = f"""<!DOCTYPE html>
<html lang="en" data-lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(TABLES[DEFAULT_LANGUAGE]["chrome"].get("page.title", "FormatForge"))}</title>
<meta name="description" content="{html.escape(TABLES[DEFAULT_LANGUAGE]["chrome"].get("page.description", "").format(tools=len(tools)))}">
<link rel="stylesheet" href="assets/style.css">
</head>
<body>
<a id="top"></a>
<div class="layout">
<aside class="sidebar">
  <div class="brand">
    <div class="mark">FF</div>
    <div><b>FormatForge</b><span>{ml_chrome("page.subtitle")}</span></div>
  </div>
  {toolbar}
  <div class="sidebar-scroll">{nav}</div>
</aside>
<main class="main">
<div class="hero">
  <h1>{ml_chrome("page.title")}</h1>
  <p class="lede">{ml_chrome("page.lede", tools=len(tools), lines=f"{total_lines:,}")}</p>
  <div class="stats">
    <div class="stat"><b>{len(tools)}</b><span>{ml_chrome("stat.toolsUnit")}</span></div>
    <div class="stat"><b>{total_params}</b><span>{ml_chrome("stat.paramsShort")}</span></div>
    <div class="stat"><b>{total_presets}</b><span>{ml_chrome("stat.presetsShort")}</span></div>
    <div class="stat"><b>{total_lines:,}</b><span>{ml_chrome("stat.linesShort")}</span></div>
  </div>
</div>
{"".join(body)}
<footer>
  <p>{ml_chrome("page.footer")}</p>
  <p>{ml_chrome("page.footerDetail")}</p>
</footer>
</main>
</div>
<a class="top-link" href="#top" title="{ml_chrome("top.backToTop", quote=True)}">↑</a>
<script src="assets/app.js"></script>
</body>
</html>
"""
    (OUT / "index.html").write_text(page, encoding="utf-8")

    size = sum(f.stat().st_size for f in OUT.rglob("*") if f.is_file())
    print(f"{chrome('log.generated')}{OUT/'index.html'}")
    print(f"{chrome('log.tools')}{len(tools)}{chrome('log.files')}{len(swift_files)}")
    print(f"{chrome('log.totalSize')}{size/1024/1024:.1f}{chrome('log.mb')}")


if __name__ == "__main__":
    main()
