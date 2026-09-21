#!/bin/bash
# Guard against a bash quirk that has bitten this project repeatedly:
# a variable immediately followed by a multi-byte character can absorb the
# character's first byte into the variable name, producing a bogus
# "unbound variable" error at runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAILED=0
for script in build.sh test.sh run.sh make-dmg.sh Scripts/*.sh; do
    [[ -f "$script" ]] || continue
    # Syntax check.
    if ! bash -n "$script" 2>/dev/null; then
        echo "✗ $script has a syntax error"
        bash -n "$script" || true
        FAILED=1
        continue
    fi
    # Unbraced variable followed by a non-ASCII byte.
    if python3 - "$script" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8").read()
bad = re.findall(r'\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]', data)
sys.exit(1 if bad else 0)
PY
    then
        echo "✓ $script"
    else
        echo "✗ $script has a variable followed by a multibyte character (write \${VAR})"
        FAILED=1
    fi
done
exit $FAILED
