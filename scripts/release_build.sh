#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_CHECK='import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'
# On Apple Silicon the interpreter must be native arm64. A Rosetta-translated
# x86_64 Python spawns MATLAB, uname, and cargo as x86_64 children, so MATLAB
# looks for bin/maci64 and the MEX extension is mislabelled mexmaci64.
NATIVE_ARCH_CHECK='import platform, sys; raise SystemExit(0 if platform.machine() == "arm64" else 1)'
REQUIRE_ARM64=0
if [ "$(uname -s)" = "Darwin" ] &&
   [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
    REQUIRE_ARM64=1
fi
PYTHON_COMMAND=()

python_is_usable() {
    "$@" -c "$VERSION_CHECK" >/dev/null 2>&1 || return 1
    if [ "$REQUIRE_ARM64" = "1" ]; then
        "$@" -c "$NATIVE_ARCH_CHECK" >/dev/null 2>&1 || return 1
    fi
    return 0
}

# Fallbacks after PATH: Homebrew (unversioned, then newest versioned) and the
# Apple-shipped universal python3.
HOMEBREW_PYTHONS=()
while IFS= read -r line; do
    [ -n "$line" ] && HOMEBREW_PYTHONS+=("$line")
done < <(ls /opt/homebrew/bin/python3.[0-9]* 2>/dev/null | sort -t. -k2,2nr)
for candidate in python3 python /opt/homebrew/bin/python3 ${HOMEBREW_PYTHONS[@]+"${HOMEBREW_PYTHONS[@]}"} /usr/bin/python3; do
    if command -v "$candidate" >/dev/null 2>&1 && python_is_usable "$candidate"; then
        PYTHON_COMMAND=("$candidate")
        break
    fi
done
if [ "${#PYTHON_COMMAND[@]}" -eq 0 ] &&
   command -v py >/dev/null 2>&1 && python_is_usable py -3; then
    PYTHON_COMMAND=(py -3)
fi
if [ "${#PYTHON_COMMAND[@]}" -eq 0 ]; then
    if [ "$REQUIRE_ARM64" = "1" ]; then
        printf '%s\n' \
            'The controlled rebuild requires a native arm64 Python 3.9 or newer.' \
            "The python3 on PATH ($(command -v python3 || echo none)) is not native arm64;" \
            'install an Apple Silicon build (e.g. brew install python) and rerun bootstrap.sh.' >&2
    else
        printf '%s\n' \
            'The controlled rebuild requires Python 3.9 or newer.' \
            'Install Python 3, then rerun bootstrap.sh.' >&2
    fi
    exit 1
fi

cd "$REPO_ROOT"
exec "${PYTHON_COMMAND[@]}" -m scripts.release_build "$@"
