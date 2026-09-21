#!/usr/bin/env python3
"""Replace Chinese string literals in the Swift sources with L("key") lookups.

The naive approach (regex per line) breaks on three things that really occur in
this codebase:

1. String literals spanning several lines, e.g.
       summary: "first part"
                "second part"
2. Interpolations containing their own string literals, e.g.
       "\(String(format: "%.2f", x)) seconds total"
3. Escaped quotes and backslashes inside literals.

So this walks the file character by character, tracking whether it is inside a
string, inside an interpolation, or in code, and only rewrites literals it has
fully and correctly delimited.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
SRC = ROOT / "Sources"
KEYS = ROOT / "build/i18n/keys.json"

CJK = re.compile(r"[\u4e00-\u9fff]")


class Scanner:
    """Finds top-level string literals in Swift source.

    Yields (start, end, body) where body is the raw text between the quotes,
    with interpolation backslashes intact.
    """

    def __init__(self, text: str):
        self.text = text
        self.i = 0
        self.n = len(text)
        self.spans = []          # (start_index_of_quote, end_index_after_quote, body)

    def scan(self):
        while self.i < self.n:
            c = self.text[self.i]

            # Line comment: skip to end of line.
            if c == "/" and self._peek(1) == "/":
                nl = self.text.find("\n", self.i)
                self.i = self.n if nl == -1 else nl
                continue

            # Block comment: skip, tracking nesting.
            if c == "/" and self._peek(1) == "*":
                depth, self.i = 1, self.i + 2
                while self.i < self.n and depth:
                    if self.text.startswith("/*", self.i):
                        depth += 1; self.i += 2
                    elif self.text.startswith("*/", self.i):
                        depth -= 1; self.i += 2
                    else:
                        self.i += 1
                continue

            # A multi-line literal (""" … """) is not used in this project for
            # UI text, but handle it so we do not mis-scan.
            if self.text.startswith('"""', self.i):
                self.i = self._skip_multiline(self.i)
                continue

            if c == '"':
                self._read_literal()
                continue

            self.i += 1
        return self.spans

    def _peek(self, offset: int) -> str:
        j = self.i + offset
        return self.text[j] if j < self.n else ""

    def _skip_multiline(self, start: int) -> int:
        end = self.text.find('"""', start + 3)
        return self.n if end == -1 else end + 3

    def _read_literal(self):
        """Read one string literal starting at self.i (which is a quote)."""
        start = self.i
        self.i += 1
        body_start = self.i
        pieces = []          # literal text pieces, with interpolations replaced

        while self.i < self.n:
            c = self.text[self.i]

            if c == "\\":
                nxt = self._peek(1)
                if nxt == "(":
                    # Interpolation: copy it verbatim, tracking nested parens
                    # and nested string literals.
                    self.i += 2
                    depth = 1
                    while self.i < self.n and depth:
                        ch = self.text[self.i]
                        if ch == '"':
                            self._read_literal()      # nested literal
                            continue
                        if ch == "\\":
                            self.i += 2
                            continue
                        if ch == "(":
                            depth += 1
                        elif ch == ")":
                            depth -= 1
                        self.i += 1
                    continue
                # A normal escape such as \" or \n.
                self.i += 2
                continue

            if c == '"':
                break

            self.i += 1

        body = self.text[body_start:self.i]
        end = self.i + 1              # include the closing quote
        self.i = end
        self.spans.append((start, end, body))


# Matches a top-level interpolation: \( ... ) with balanced parens.
INTERP = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")


def swift_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def build_replacement(body: str, key: str) -> str:
    """Turn a literal body into an L(...) call, preserving interpolations."""
    parts = []
    last = 0
    for m in INTERP.finditer(body):
        if m.start() > last:
            parts.append(("text", body[last:m.start()]))
        parts.append(("expr", m.group(0)[2:-1]))   # strip \( and )
        last = m.end()
    if last < len(body):
        parts.append(("text", body[last:]))

    expressions = [value for kind, value in parts if kind == "expr"]
    if not expressions:
        return f'L("{key}")'
    args = ", ".join(e.strip() for e in expressions)
    return f'L("{key}", {args})'


def main():
    if not KEYS.exists():
        sys.exit("run Tools/i18n/assign-keys.py first")

    mapping = json.loads(KEYS.read_text(encoding="utf-8"))
    by_text = {entry["zh"]: key for key, entry in mapping.items()}

    changed_files = 0
    replaced = 0
    unmatched = set()

    for path in sorted(SRC.rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        scanner = Scanner(text)
        spans = scanner.scan()

        # Rewrite from the end so earlier offsets stay valid.
        output = text
        file_hits = 0
        for start, end, body in reversed(spans):
            if not CJK.search(body):
                continue
            key = by_text.get(body)
            if key is None:
                unmatched.add(body)
                continue
            output = output[:start] + build_replacement(body, key) + output[end:]
            file_hits += 1

        if file_hits:
            path.write_text(output, encoding="utf-8")
            changed_files += 1
            replaced += file_hits
            print(f"  {file_hits:4d}  {path.relative_to(ROOT)}")

    print(f"\nRewrote {replaced} literals across {changed_files} files")
    if unmatched:
        print(f"Unmatched: {len(unmatched)}")
        for u in sorted(unmatched)[:20]:
            print(f"  {u!r}")


if __name__ == "__main__":
    main()
