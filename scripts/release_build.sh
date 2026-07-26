#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_CHECK='import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'
PYTHON_COMMAND=()

if command -v python3 >/dev/null 2>&1 &&
   python3 -c "$VERSION_CHECK" >/dev/null 2>&1; then
    PYTHON_COMMAND=(python3)
elif command -v python >/dev/null 2>&1 &&
     python -c "$VERSION_CHECK" >/dev/null 2>&1; then
    PYTHON_COMMAND=(python)
elif command -v py >/dev/null 2>&1 &&
     py -3 -c "$VERSION_CHECK" >/dev/null 2>&1; then
    PYTHON_COMMAND=(py -3)
else
    printf '%s\n' \
        'The controlled rebuild requires Python 3.9 or newer.' \
        'Install Python 3, then rerun bootstrap.sh.' >&2
    exit 1
fi

cd "$REPO_ROOT"
exec "${PYTHON_COMMAND[@]}" -m scripts.release_build "$@"
