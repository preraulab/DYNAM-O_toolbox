#!/usr/bin/env python3
"""Fail when distributable artifacts contain build-machine paths."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Iterable, Sequence


GENERIC_PATHS = (
    b"/Users/",
    b"/home/",
    b"/homes/",
    b"/root/",
    b"/tmp/",
    b"/private/tmp/",
    b"/var/tmp/",
    b"/var/folders/",
    b"/private/var/folders/",
    b"C:\\Users\\",
    b"C:/Users/",
)

# Exact sensitive needles below catch known build roots regardless of shape. The
# generic fallbacks require plausible multi-component structure because short
# path-shaped byte runs are otherwise indistinguishable from encoded LLVM bitcode.
_ASCII_WINDOWS_DRIVE_CANDIDATE = re.compile(
    rb"[A-Za-z]:[\\/](?:(?![<>:\"|?*])[ -~]){2,300}"
)
_UTF16LE_WINDOWS_DRIVE_CANDIDATE = re.compile(
    rb"[A-Za-z]\x00:\x00[\\/]\x00"
    rb"(?:(?![<>:\"|?*]\x00)[ -~]\x00){2,300}"
)
_ASCII_WINDOWS_UNC_CANDIDATE = re.compile(
    rb"(?<![\\/])\\{2,4}"
    rb"(?:[?]\\{1,2}[Uu][Nn][Cc]\\{1,2})?"
    rb"(?:(?![<>:\"|?*])[ -~]){3,300}"
)
_UTF16LE_WINDOWS_UNC_CANDIDATE = re.compile(
    rb"(?<![\\/]\x00)(?:\\\x00){2,4}"
    rb"(?:[?]\x00(?:\\\x00){1,2}"
    rb"[Uu]\x00[Nn]\x00[Cc]\x00(?:\\\x00){1,2})?"
    rb"(?:(?![<>:\"|?*]\x00)[ -~]\x00){3,300}"
)


def _path_variants(path: str) -> set[bytes]:
    raw = os.path.expanduser(path).rstrip("/\\")
    variants = {
        raw,
        os.path.abspath(raw).rstrip("/\\"),
        os.path.realpath(raw).rstrip("/\\"),
    }
    variants.update(value.replace("\\", "/") for value in list(variants))
    variants.update(value.replace("/", "\\") for value in list(variants))
    variants.update(value.replace("\\", "\\\\") for value in list(variants))
    return {
        encoded
        for variant in variants
        if variant
        for encoded in (variant.encode(), variant.encode("utf-16-le"))
    }


def sensitive_needles(paths: Iterable[str]) -> set[bytes]:
    needles = {
        encoded
        for prefix in GENERIC_PATHS
        for encoded in (prefix, prefix.decode().encode("utf-16-le"))
    }
    for path in paths:
        if path:
            needles.update(_path_variants(path))
    return needles


def _windows_valid_prefix(value: str) -> str:
    return re.split(r'[<>:"|?*]', value, maxsplit=1)[0]


def _windows_components(value: str) -> list[str]:
    valid_prefix = _windows_valid_prefix(value)
    return [part for part in re.split(r"[\\/]+", valid_prefix) if part]


def _has_substantive_windows_component(components: Sequence[str]) -> bool:
    return any(
        sum(character.isascii() and character.isalnum() for character in component)
        >= 2
        for component in components
    )


def _looks_like_windows_drive_path(value: str) -> bool:
    components = _windows_components(value[3:])
    if len(components) < 2:
        return False
    return len(components) >= 3 or (
        len(components[0]) >= 2
        and len(components[1]) >= 2
        and _has_substantive_windows_component(components)
    )


def _looks_like_windows_unc_path(value: str) -> bool:
    leading_backslashes = len(value) - len(value.lstrip("\\"))
    if leading_backslashes not in (2, 4):
        return False
    serialized = leading_backslashes == 4
    tail = value[leading_backslashes:]
    extended_prefix = "?\\\\unc\\\\" if serialized else "?\\unc\\"
    if tail.lower().startswith(extended_prefix):
        tail = tail[len(extended_prefix) :]
    elif tail.startswith("?"):
        return False
    valid_tail = _windows_valid_prefix(tail)
    separator_width = 2 if serialized else 1
    if any(
        len(separator) != separator_width
        for separator in re.findall(r"\\+", valid_tail)
    ):
        return False
    components = [part for part in re.split(r"\\+", valid_tail) if part]
    if len(components) < 2:
        return False
    server, share = components[:2]
    if not re.fullmatch(r"[A-Za-z0-9._-]+", server):
        return False
    server_alphanumerics = sum(
        character.isascii() and character.isalnum() for character in server
    )
    return _has_substantive_windows_component(components) and (
        len(components) >= 3
        or (server_alphanumerics >= 2 and len(share) >= 2)
    )


def scan_bytes(data: bytes, label: str, needles: set[bytes]) -> list[str]:
    findings = []
    for needle in sorted(needles, key=len, reverse=True):
        if needle and needle in data:
            encoding = "UTF-16LE" if b"\x00" in needle else "ASCII"
            display = needle.decode(
                "utf-16-le" if encoding == "UTF-16LE" else "utf-8",
                errors="replace",
            )
            findings.append(f"{label}: {encoding} path marker {display!r}")
    for match in _ASCII_WINDOWS_DRIVE_CANDIDATE.finditer(data):
        if data[match.start() + 2 : match.start() + 4] == b"//":
            continue
        display = match.group(0).decode(errors="replace")
        if not _looks_like_windows_drive_path(display):
            continue
        findings.append(
            f"{label}: ASCII absolute Windows path {display!r}"
        )
    for match in _UTF16LE_WINDOWS_DRIVE_CANDIDATE.finditer(data):
        if data[match.start() + 4 : match.start() + 8] == b"/\x00/\x00":
            continue
        display = match.group(0).decode("utf-16-le", errors="replace")
        if not _looks_like_windows_drive_path(display):
            continue
        findings.append(
            f"{label}: UTF-16LE absolute Windows path {display!r}"
        )
    for match in _ASCII_WINDOWS_UNC_CANDIDATE.finditer(data):
        display = match.group(0).decode(errors="replace")
        if not _looks_like_windows_unc_path(display):
            continue
        findings.append(
            f"{label}: ASCII absolute Windows UNC path {display!r}"
        )
    for match in _UTF16LE_WINDOWS_UNC_CANDIDATE.finditer(data):
        display = match.group(0).decode("utf-16-le", errors="replace")
        if not _looks_like_windows_unc_path(display):
            continue
        findings.append(
            f"{label}: UTF-16LE absolute Windows UNC path {display!r}"
        )
    return findings


def _run_inspector(command: Sequence[str], path: Path) -> tuple[str, list[str]]:
    try:
        result = subprocess.run(
            (*command, str(path)),
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        return "", [f"{path}: loader inspection failed: {exc}"]
    if result.returncode:
        return "", [
            f"{path}: {' '.join(command)} failed with exit code {result.returncode}"
        ]
    return result.stdout, []


def _macho_findings(path: Path) -> list[str]:
    if not shutil.which("otool"):
        return [f"{path}: otool is required to inspect this Mach-O artifact"]
    output, findings = _run_inspector(("otool", "-L"), path)
    for line in output.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if dependency.startswith("/") and not dependency.startswith(
            ("/usr/lib/", "/System/Library/", "/Library/Apple/System/Library/")
        ):
            findings.append(f"{path}: absolute Mach-O dependency {dependency!r}")

    load_commands, errors = _run_inspector(("otool", "-l"), path)
    findings.extend(errors)
    lines = load_commands.splitlines()
    for index, line in enumerate(lines):
        if line.strip() != "cmd LC_RPATH":
            continue
        for candidate in lines[index + 1 : index + 5]:
            match = re.match(r"\s*path (.+?) \(offset \d+\)", candidate)
            if match and match.group(1).startswith("/"):
                findings.append(
                    f"{path}: absolute Mach-O LC_RPATH {match.group(1)!r}"
                )
                break
    return findings


def _elf_findings(path: Path) -> list[str]:
    inspector = shutil.which("readelf")
    if not inspector:
        return [f"{path}: readelf is required to inspect this ELF artifact"]
    output, findings = _run_inspector((inspector, "-d"), path)
    for line in output.splitlines():
        needed = re.search(r"\(NEEDED\).*Shared library: \[(.+)\]", line)
        if needed and "/" in needed.group(1):
            findings.append(
                f"{path}: ELF NEEDED entry contains a path {needed.group(1)!r}"
            )
        search_path = re.search(
            r"\((?:RPATH|RUNPATH)\).*Library (?:rpath|runpath): \[(.*)\]", line
        )
        if search_path:
            for entry in search_path.group(1).split(":"):
                if entry.startswith("/"):
                    findings.append(f"{path}: absolute ELF search path {entry!r}")
    return findings


def _binary_format(data: bytes) -> str | None:
    if data.startswith(b"\x7fELF"):
        return "ELF"
    if data[:4] in {
        b"\xfe\xed\xfa\xce",
        b"\xce\xfa\xed\xfe",
        b"\xfe\xed\xfa\xcf",
        b"\xcf\xfa\xed\xfe",
        b"\xca\xfe\xba\xbe",
        b"\xbe\xba\xfe\xca",
        b"\xca\xfe\xba\xbf",
        b"\xbf\xba\xfe\xca",
    }:
        return "Mach-O"
    if data.startswith(b"MZ") and len(data) >= 64:
        pe_offset = int.from_bytes(data[60:64], "little")
        if data[pe_offset : pe_offset + 4] == b"PE\0\0":
            return "PE"
    return None


def _expected_native_formats(path: Path) -> set[str]:
    suffix = path.suffix.lower()
    if suffix == ".mexa64":
        return {"ELF"}
    if suffix in {".mexmaci64", ".mexmaca64", ".dylib"}:
        return {"Mach-O"}
    if suffix in {".mexw64", ".dll", ".pyd"}:
        return {"PE"}
    if suffix == ".so":
        return {"ELF", "Mach-O"}
    return set()


def loader_findings(path: Path, data: bytes) -> list[str]:
    binary_format = _binary_format(data)
    expected = _expected_native_formats(path)
    if expected and binary_format not in expected:
        return [
            f"{path}: expected {' or '.join(sorted(expected))} native binary, "
            f"found {binary_format or 'unrecognized data'}"
        ]
    if binary_format == "ELF":
        return _elf_findings(path)
    if binary_format == "Mach-O":
        return _macho_findings(path)
    return []


def archive_loader_findings(data: bytes, label: str) -> list[str]:
    member_path = Path(label)
    binary_format = _binary_format(data)
    if binary_format is None:
        return loader_findings(member_path, data)

    with tempfile.NamedTemporaryFile(
        suffix=member_path.suffix, delete=False
    ) as handle:
        handle.write(data)
        temporary = Path(handle.name)
    try:
        findings = loader_findings(temporary, data)
    finally:
        temporary.unlink(missing_ok=True)
    return [finding.replace(str(temporary), label) for finding in findings]


def scan_file(path: Path, needles: set[bytes]) -> list[str]:
    try:
        data = path.read_bytes()
    except OSError as exc:
        return [f"{path}: could not read artifact: {exc}"]

    if path.suffix.lower() not in {".whl", ".zip"}:
        findings = scan_bytes(data, str(path), needles)
        findings.extend(loader_findings(path, data))
        return findings

    findings = []
    try:
        with zipfile.ZipFile(path) as archive:
            for member in archive.infolist():
                if member.is_dir():
                    continue
                member_label = f"{path}!{member.filename}"
                findings.extend(
                    scan_bytes(member.filename.encode(), member_label, needles)
                )
                try:
                    member_data = archive.read(member)
                except (OSError, RuntimeError, zipfile.BadZipFile) as exc:
                    findings.append(f"{member_label}: could not read: {exc}")
                    continue
                findings.extend(
                    scan_bytes(member_data, member_label, needles)
                )
                findings.extend(
                    archive_loader_findings(member_data, member_label)
                )
    except (OSError, zipfile.BadZipFile) as exc:
        findings.append(f"{path}: invalid archive: {exc}")
    return findings


def scan_artifacts(
    artifacts: Sequence[Path], sensitive_paths: Iterable[str]
) -> list[str]:
    needles = sensitive_needles(sensitive_paths)
    findings = []
    for artifact in artifacts:
        if not artifact.is_file():
            findings.append(f"{artifact}: expected artifact is missing")
            continue
        findings.extend(scan_file(artifact, needles))
    return findings


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Reject native artifacts and wheels containing host paths."
    )
    parser.add_argument(
        "--sensitive-path",
        action="append",
        default=[],
        help="Exact local path to reject (repeatable).",
    )
    parser.add_argument("artifacts", nargs="+", type=Path)
    return parser.parse_args()


def main() -> int:
    args = _arguments()
    findings = scan_artifacts(args.artifacts, args.sensitive_path)
    if findings:
        print("Privacy gate failed:", file=sys.stderr)
        for finding in findings:
            print(f"  - {finding}", file=sys.stderr)
        return 1
    print(f"Privacy gate passed for {len(args.artifacts)} artifact(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
