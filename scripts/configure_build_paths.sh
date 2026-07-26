#!/usr/bin/env bash

# Add privacy-preserving source path mappings without whitespace splitting.
configure_build_paths() {
    local root="$1"
    local separator=$'\x1f'
    local encoded=""
    local source destination canonical flag

    if [ -n "${RUSTFLAGS:-}" ]; then
        printf '%s\n' \
            "RUSTFLAGS is set and cannot be combined safely with path remapping." \
            "Unset it or express it with CARGO_ENCODED_RUSTFLAGS." >&2
        return 2
    fi
    if [[ "${CARGO_ENCODED_RUSTFLAGS:-}" == *"--remap-path-prefix="* ]] ||
       [[ "${CARGO_ENCODED_RUSTFLAGS:-}" == *"--remap-path-scope="* ]]; then
        printf '%s\n' \
            "CARGO_ENCODED_RUSTFLAGS already controls path remapping." \
            "Remove it so this build can apply the controlled mappings." >&2
        return 2
    fi

    append_mapping() {
        source="$1"
        destination="$2"
        [ -d "$source" ] || return 0
        canonical="$(cd "$source" && pwd -P)"
        flag="--remap-path-prefix=$canonical=$destination"
        encoded="${encoded:+$encoded$separator}$flag"
    }

    append_mapping "$HOME" /build/user
    append_mapping "${TMPDIR:-/tmp}" /build/tmp
    append_mapping "${CARGO_HOME:-$HOME/.cargo}" /build/cargo
    append_mapping "${RUSTUP_HOME:-$HOME/.rustup}" /build/rustup
    append_mapping "$root" /workspace
    encoded="$encoded$separator--remap-path-scope=object"

    if [ -n "${CARGO_ENCODED_RUSTFLAGS:-}" ]; then
        encoded="$encoded$separator$CARGO_ENCODED_RUSTFLAGS"
    fi
    export CARGO_ENCODED_RUSTFLAGS="$encoded"
}

sanitize_maturin_sboms() {
    local root="$1" python="$2" venv="$3" distribution="$4"
    local sanitizer="$root/DYNAM-O_rs/scripts/sanitize_maturin_sbom.py"
    local targets=()
    local mappings=(
        --map "$root=/workspace"
        --map "${CARGO_HOME:-$HOME/.cargo}=/build/cargo"
        --map "${RUSTUP_HOME:-$HOME/.rustup}=/build/rustup"
        --map "${TMPDIR:-/tmp}=/build/tmp"
        --map "$HOME=/build/user"
    )
    local target

    if [ ! -f "$sanitizer" ]; then
        printf 'SBOM sanitizer not found; local SBOMs were not sanitized: %s\n' \
            "$sanitizer" >&2
        return 0
    fi
    while IFS= read -r -d '' target; do
        targets+=("$target")
    done < <(
        find "$venv" -type d -path "*/$distribution-*.dist-info/sboms" -print0
    )
    [ "${#targets[@]}" -gt 0 ] || return 0
    "$python" "$sanitizer" "${mappings[@]}" "${targets[@]}"
    "$python" "$sanitizer" "${mappings[@]}" --check "${targets[@]}"
}
