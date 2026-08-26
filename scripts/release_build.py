#!/usr/bin/env python3
"""Build release artifacts from bootstrap-synchronized master checkouts."""

from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, Optional, Sequence

from scripts.privacy_gate import scan_artifacts, scan_bytes, sensitive_needles


ROOT = Path(__file__).resolve().parent.parent
REPOSITORIES = ("DYNAM-O_rs", "DYNAM-O", "DYNAM-O_py")
CANONICAL_REPOSITORY_URLS = {
    name: f"https://github.com/preraulab/{name}.git" for name in REPOSITORIES
}
MATURIN_VERSION = "1.14.1"
UNIT_SEPARATOR = "\x1f"
MEX_WRAPPERS = (
    "extract_tfpeaks_mex",
    "refine_peaks_mex",
    "tfpeak_histogram_mex",
    "mask_spectrogram_mex",
    "multitaper_spectrogram_rust_mex",
    "dpss_rust_mex",
    "detect_artifacts_mex",
    "baseline_mex",
    "so_power_mex",
    "so_phase_mex",
    "dynamo_version_mex",
)
NATIVE_BINARY_SUFFIXES = {
    ".dll",
    ".dylib",
    ".mexa64",
    ".mexmaca64",
    ".mexmaci64",
    ".mexw64",
    ".pdb",
    ".so",
}


def run(
    command: Sequence[str],
    *,
    cwd: Path = ROOT,
    env: Optional[Dict[str, str]] = None,
    capture: bool = False,
) -> str:
    print(f"[release] {cwd.name}: running {Path(command[0]).name}")
    result = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout.rstrip("\r\n") if capture else ""


def git(repo: Path, *arguments: str, capture: bool = False) -> str:
    return run(("git", *arguments), cwd=repo, capture=capture)


def require_clean(repo: Path) -> None:
    status = git(repo, "status", "--porcelain", "--untracked-files=normal", capture=True)
    if status:
        raise RuntimeError(f"{repo.name} has uncommitted or untracked files")


def validate_origin(repo: Path) -> None:
    origin = git(repo, "remote", "get-url", "origin", capture=True)
    name = repo.name
    allowed = {
        CANONICAL_REPOSITORY_URLS[name],
        CANONICAL_REPOSITORY_URLS[name].removesuffix(".git"),
        f"git@github.com:preraulab/{name}",
        f"git@github.com:preraulab/{name}.git",
        f"ssh://git@github.com/preraulab/{name}",
        f"ssh://git@github.com/preraulab/{name}.git",
    }
    if origin not in allowed:
        raise RuntimeError(
            f"{name} origin is not the expected preraulab/{name} repository: "
            f"{origin}"
        )


def validate_master(repo: Path) -> str:
    validate_origin(repo)
    require_clean(repo)
    branch = git(repo, "symbolic-ref", "--short", "HEAD", capture=True)
    if branch != "master":
        raise RuntimeError(
            f"{repo.name} is on {branch!r}, not master; run bootstrap first"
        )
    head = git(repo, "rev-parse", "HEAD", capture=True)
    remote_output = git(
        repo,
        "ls-remote",
        "--exit-code",
        "origin",
        "refs/heads/master",
        capture=True,
    )
    remote = remote_output.split(None, 1)[0]
    if head != remote:
        raise RuntimeError(
            f"{repo.name}/master is not exactly at the current origin/master; "
            "run bootstrap first"
        )
    submodule_status = git(repo, "submodule", "status", "--recursive", capture=True)
    mismatches = [
        line for line in submodule_status.splitlines() if not line.startswith(" ")
    ]
    if mismatches:
        raise RuntimeError(
            f"{repo.name} has submodules that do not match recorded gitlinks: "
            + "; ".join(mismatches)
        )
    require_clean(repo)
    return head


def source_path_variants(value: str) -> list[str]:
    raw = os.path.expanduser(value).rstrip("/\\")
    variants = {
        raw,
        os.path.abspath(raw).rstrip("/\\"),
        os.path.realpath(raw).rstrip("/\\"),
    }
    variants.update(candidate.replace("\\", "/") for candidate in list(variants))
    if os.name == "nt":
        variants.update(candidate.replace("/", "\\") for candidate in list(variants))
    return sorted(
        (candidate for candidate in variants if candidate),
        key=lambda candidate: (len(candidate), candidate),
    )


def remap_flags(root: Path, environ: dict[str, str]) -> str:
    mappings: list[tuple[str, str]] = []
    for value, destination in (
        (str(Path.home()), "/build/user"),
        (tempfile.gettempdir(), "/build/temporary"),
        (environ.get("CARGO_HOME") or str(Path.home() / ".cargo"), "/build/cargo"),
        (environ.get("RUSTUP_HOME") or str(Path.home() / ".rustup"), "/build/rustup"),
    ):
        mappings.extend(
            (variant, destination) for variant in source_path_variants(value)
        )

    working_directory = environ.get("PWD")
    if working_directory and os.path.realpath(working_directory) == os.path.realpath(
        root
    ):
        mappings.extend(
            (variant, "/workspace")
            for variant in source_path_variants(working_directory)
        )
    mappings.extend(
        (variant, "/workspace")
        for variant in source_path_variants(str(root))
    )
    mappings.sort(key=lambda item: (len(item[0]), item[0]))

    flags = []
    seen = set()
    for source, destination in mappings:
        flag = f"--remap-path-prefix={source}={destination}"
        if flag not in seen:
            flags.append(flag)
            seen.add(flag)
    flags.append("--remap-path-scope=all")
    return UNIT_SEPARATOR.join(flags)


def release_environment() -> dict[str, str]:
    controlled_variables = (
        "RUSTFLAGS",
        "CARGO_ENCODED_RUSTFLAGS",
        "CARGO_TARGET_DIR",
        "CARGO_BUILD_TARGET",
    )
    for variable in controlled_variables:
        if os.environ.get(variable):
            raise RuntimeError(
                f"{variable} is already set; unset it before a controlled release build"
            )
    env = os.environ.copy()
    for variable in controlled_variables:
        env.pop(variable, None)
    env["CARGO_ENCODED_RUSTFLAGS"] = remap_flags(ROOT, env)
    return env


def cargo_target_directory(crate: Path) -> Path:
    crate = crate.resolve()
    target = crate / "target"
    for directory in (target, target / "release", target / "release" / "deps"):
        if directory.is_symlink():
            raise RuntimeError(
                f"refusing symlinked Cargo target directory: {directory}"
            )
        if directory.exists() and not directory.is_dir():
            raise RuntimeError(f"Cargo target path is not a directory: {directory}")
        if not directory.resolve().is_relative_to(crate):
            raise RuntimeError(f"Cargo target directory escapes its crate: {directory}")
    return target


def cargo_environment(env: dict[str, str], crate: Path) -> dict[str, str]:
    target = cargo_target_directory(crate)
    cargo_env = env.copy()
    cargo_env["CARGO_TARGET_DIR"] = str(target)
    return cargo_env


def remove_stale_artifact(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        return
    if not path.is_file() and not path.is_symlink():
        raise RuntimeError(f"expected artifact path is not a file: {path}")
    path.unlink()


def require_fresh_artifact(path: Path, producer: str) -> None:
    if not path.is_file():
        raise RuntimeError(
            f"{producer} did not create the expected artifact at {path}; "
            "check for a configured Cargo build target"
        )


def require_absent_artifact(path: Path, producer: str) -> None:
    if path.exists() or path.is_symlink():
        raise RuntimeError(f"{producer} unexpectedly created forbidden artifact {path}")


def forbidden_static_archives(target: Path) -> tuple[Path, ...]:
    names = (
        "libdynamo_rs.a",
        "dynamo_rs.lib",
        "libdynamo_rs.lib",
    )
    return tuple(
        directory / name
        for directory in (target / "release", target / "release" / "deps")
        for name in names
    )


def dynamo_rlib_artifacts(target: Path) -> list[Path]:
    return sorted(
        {
            path
            for directory in (target / "release", target / "release" / "deps")
            for pattern in ("libdynamo_rs*.rlib", "dynamo_rs*.rlib")
            for path in directory.glob(pattern)
            if path.is_file()
        }
    )


def find_matlab() -> Path:
    executable = shutil.which("matlab")
    if executable:
        return Path(executable)
    candidates: Iterable[Path]
    if sys.platform == "darwin":
        candidates = Path("/Applications").glob("MATLAB*.app/bin/matlab")
    elif os.name == "nt":
        candidates = Path("C:/Program Files/MATLAB").glob("*/bin/matlab.exe")
    else:
        candidates = (
            path
            for base in (Path("/usr/local/MATLAB"), Path("/opt/MATLAB"))
            for path in base.glob("R*/bin/matlab")
        )
    existing = sorted(path for path in candidates if path.is_file())
    if not existing:
        raise RuntimeError("MATLAB is required to produce release MEX files")
    return existing[-1]


def venv_commands(venv: Path) -> tuple[Path, Path]:
    scripts = venv / ("Scripts" if os.name == "nt" else "bin")
    python = scripts / ("python.exe" if os.name == "nt" else "python")
    pip = scripts / ("pip.exe" if os.name == "nt" else "pip")
    return python, pip


def site_packages_path(venv: Path) -> Path:
    if os.name == "nt":
        return venv / "Lib" / "site-packages"
    matches = sorted((venv / "lib").glob("python*/site-packages"))
    if len(matches) != 1:
        raise RuntimeError(f"could not identify site-packages under {venv}")
    return matches[0]


def sanitize_sboms(python: Path, venv: Path, env: dict[str, str]) -> None:
    sanitizer = ROOT / "DYNAM-O_rs" / "scripts" / "sanitize_maturin_sbom.py"
    if not sanitizer.is_file():
        raise RuntimeError(f"required SBOM sanitizer is missing: {sanitizer}")
    site_packages = site_packages_path(venv)
    sbom_directories = sorted(
        path
        for distribution in ("dynamo_rs-*.dist-info", "multitaper_rs-*.dist-info")
        for path in site_packages.glob(f"{distribution}/sboms")
    )
    if not sbom_directories:
        return

    arguments = [str(python), str(sanitizer)]
    mappings = [
        (str(ROOT), "/workspace"),
        (env.get("CARGO_HOME") or str(Path.home() / ".cargo"), "/build/cargo"),
        (env.get("RUSTUP_HOME") or str(Path.home() / ".rustup"), "/build/rustup"),
        (tempfile.gettempdir(), "/build/temporary"),
        (str(Path.home()), "/build/user"),
    ]
    working_directory = env.get("PWD")
    if working_directory and os.path.realpath(working_directory) == os.path.realpath(
        ROOT
    ):
        mappings.append((working_directory, "/workspace"))

    seen_mappings = set()
    for source, destination in mappings:
        for variant in source_path_variants(source):
            mapping = f"{variant}={destination}"
            if mapping in seen_mappings:
                continue
            seen_mappings.add(mapping)
            arguments.extend(("--map", mapping))
    targets = tuple(str(path) for path in sbom_directories)
    run((*arguments, *targets), cwd=ROOT / "DYNAM-O_rs" / "rust", env=env)
    run(
        (*arguments, "--check", *targets),
        cwd=ROOT / "DYNAM-O_rs" / "rust",
        env=env,
    )


def build_artifacts(env: dict[str, str]) -> tuple[Path, Path]:
    rust = ROOT / "DYNAM-O_rs" / "rust"
    target = cargo_target_directory(rust)
    rust_env = cargo_environment(env, rust)
    cli = target / "release" / (
        "dynamo.exe" if os.name == "nt" else "dynamo"
    )
    if os.name == "nt":
        shared_library = target / "release" / "dynamo_rs.dll"
    elif sys.platform == "darwin":
        shared_library = target / "release" / "libdynamo_rs.dylib"
    else:
        shared_library = target / "release" / "libdynamo_rs.so"
    remove_stale_artifact(cli)
    remove_stale_artifact(shared_library)
    for artifact in dynamo_rlib_artifacts(target):
        remove_stale_artifact(artifact)
    for archive in forbidden_static_archives(target):
        remove_stale_artifact(archive)
    run(
        (
            "cargo",
            "build",
            "--release",
            "--locked",
            "--bin",
            "dynamo",
            "--lib",
        ),
        cwd=rust,
        env=rust_env,
    )
    require_fresh_artifact(cli, "Cargo")
    require_fresh_artifact(shared_library, "Cargo")
    if not dynamo_rlib_artifacts(target):
        raise RuntimeError("Cargo did not freshly create the required dynamo_rs rlib")
    for archive in forbidden_static_archives(target):
        require_absent_artifact(archive, "Cargo")

    mex_dir = ROOT / "DYNAM-O" / "rust_bridge"
    matlab_path = str(mex_dir).replace("'", "''")
    matlab = find_matlab()
    run(
        (
            str(matlab),
            "-batch",
            f"cd('{matlab_path}'); build_rust_mex('prebuilt')",
        ),
        env=env,
    )

    venv = ROOT / "DYNAM-O_py" / ".venv"
    if not venv.exists():
        run((sys.executable, "-m", "venv", str(venv)), env=env)
    python, pip = venv_commands(venv)
    run(
        (
            str(pip),
            "install",
            "--quiet",
            "--upgrade",
            "pip>=21",
            "setuptools",
            "wheel",
        ),
        env=env,
    )
    run(
        (str(pip), "install", "--quiet", "--upgrade", f"maturin=={MATURIN_VERSION}"),
        env=env,
    )
    python_env = env.copy()
    python_env["VIRTUAL_ENV"] = str(venv)
    for variable in ("CONDA_PREFIX", "CONDA_DEFAULT_ENV", "CONDA_SHLVL"):
        python_env.pop(variable, None)
    run(
        (str(python), "-m", "maturin", "develop", "--release"),
        cwd=ROOT
        / "DYNAM-O"
        / "toolbox"
        / "helper_functions"
        / "multitaper_toolbox"
        / "rust",
        env=cargo_environment(
            python_env,
            ROOT
            / "DYNAM-O"
            / "toolbox"
            / "helper_functions"
            / "multitaper_toolbox"
            / "rust",
        ),
    )
    sanitize_sboms(python, venv, python_env)
    rust_python_env = cargo_environment(python_env, rust)
    run(
        (
            str(python),
            "-m",
            "maturin",
            "develop",
            "--release",
            "--locked",
            "--features",
            "python",
        ),
        cwd=rust,
        env=rust_python_env,
    )
    sanitize_sboms(python, venv, rust_python_env)
    run(
        (str(pip), "install", "--quiet", "-e", "."),
        cwd=ROOT / "DYNAM-O_py",
        env=python_env,
    )
    run(
        (str(python), "scripts/check_install.py"),
        cwd=ROOT / "DYNAM-O_py",
        env=python_env,
    )
    return venv, matlab


def platform_artifacts(venv: Path) -> list[Path]:
    if sys.platform == "darwin":
        mex_extension, library = (
            ("mexmaca64" if platform.machine() == "arm64" else "mexmaci64"),
            "libdynamo_rs.dylib",
        )
        cli = "dynamo"
    elif os.name == "nt":
        mex_extension, library, cli = "mexw64", "dynamo_rs.dll", "dynamo.exe"
    else:
        mex_extension, library, cli = "mexa64", "libdynamo_rs.so", "dynamo"

    mex_dir = ROOT / "DYNAM-O" / "rust_bridge"
    mex_files = [mex_dir / f"{stem}.{mex_extension}" for stem in MEX_WRAPPERS]
    artifacts = list(mex_files)
    artifacts.append(mex_dir / library)
    source_filters = sorted(
        (ROOT / "DYNAM-O_rs" / "data_matlab_filters").glob("*.npy")
    )
    if len(source_filters) != 42:
        raise RuntimeError(
            "DYNAM-O_rs must contain exactly 42 canonical filter-cache files; "
            f"found {len(source_filters)}"
        )
    expected_filter_names = [path.name for path in source_filters]

    target = ROOT / "DYNAM-O_rs" / "rust" / "target" / "release"
    artifacts.append(target / cli)
    artifacts.append(ROOT / "DYNAM-O_rs" / "rust" / "include" / "dynamo_rs.h")
    artifacts.extend(
        path
        for name in ("libdynamo_rs.so", "libdynamo_rs.dylib", "dynamo_rs.dll")
        if (path := target / name).exists()
    )

    site_packages = site_packages_path(venv)
    native_modules = {}
    for distribution in ("dynamo_rs", "multitaper_rs"):
        matches = sorted(
            {
                path
                for suffix in ("so", "pyd", "dylib")
                for path in site_packages.glob(f"**/{distribution}*.{suffix}")
            }
        )
        native_modules[distribution] = matches
        artifacts.extend(matches)
        if len(matches) != 1:
            artifacts.append(
                site_packages
                / f"<expected-1-{distribution}-native-module-found-{len(matches)}>"
            )

    for module in native_modules["dynamo_rs"]:
        python_filter_dir = module.parent / "data_matlab_filters"
        python_filters = [
            python_filter_dir / name for name in expected_filter_names
        ]
        actual_python_filters = sorted(
            path.name for path in python_filter_dir.glob("*.npy")
        )
        if actual_python_filters != expected_filter_names:
            raise RuntimeError("Python runtime filter cache does not match DYNAM-O_rs")
        artifacts.extend(python_filters)
    for distribution in ("dynamo_rs", "multitaper_rs"):
        sboms = sorted(
            site_packages.glob(f"{distribution}-*.dist-info/sboms/*.json")
        )
        artifacts.extend(sboms)
        if len(sboms) != 1:
            artifacts.append(
                site_packages / f"<expected-1-{distribution}-sbom-found-{len(sboms)}>"
            )

    unique = list(dict.fromkeys(artifacts))
    return unique


def rust_internal_validation_artifacts() -> list[Path]:
    target = cargo_target_directory(ROOT / "DYNAM-O_rs" / "rust")
    release = target / "release"
    rlibs = dynamo_rlib_artifacts(target)
    if not rlibs:
        raise RuntimeError("Cargo did not create the required internal dynamo_rs rlib")
    auxiliaries = {
        path
        for directory in (release, release / "deps")
        for pattern in (
            "dynamo*.pdb",
            "dynamo_rs*.dll.lib",
            "libdynamo_rs*.dll.a",
        )
        for path in directory.glob(pattern)
        if path.is_file()
    }
    artifacts = sorted(
        {
            *rlibs,
            *auxiliaries,
        }
    )
    for archive in forbidden_static_archives(target):
        require_absent_artifact(archive, "Cargo")
    return artifacts


def other_platform_binaries(current_artifacts: Sequence[Path]) -> list[Path]:
    current = set(current_artifacts)
    current_suffixes = current_platform_binary_suffixes()
    mex_dir = ROOT / "DYNAM-O" / "rust_bridge"
    return sorted(
        path
        for path in mex_dir.iterdir()
        if path.is_file()
        and path.suffix.lower() in NATIVE_BINARY_SUFFIXES
        and path.suffix.lower() not in current_suffixes
        and path not in current
    )


def current_platform_binary_suffixes() -> set[str]:
    if sys.platform == "darwin":
        mex = ".mexmaca64" if platform.machine() == "arm64" else ".mexmaci64"
        return {mex, ".dylib"}
    if os.name == "nt":
        return {".dll", ".mexw64", ".pdb"}
    return {".mexa64", ".so"}


def unexpected_current_platform_binaries(
    current_artifacts: Sequence[Path],
) -> list[Path]:
    current = set(current_artifacts)
    current_suffixes = current_platform_binary_suffixes()
    mex_dir = ROOT / "DYNAM-O" / "rust_bridge"
    return sorted(
        path
        for path in mex_dir.iterdir()
        if path.is_file()
        and path.suffix.lower() in current_suffixes
        and path not in current
    )


def scan_artifact_bytes(
    artifacts: Sequence[Path], sensitive_paths: Iterable[str]
) -> list[str]:
    needles = sensitive_needles(sensitive_paths)
    findings = []
    for artifact in artifacts:
        try:
            data = artifact.read_bytes()
        except OSError as exc:
            findings.append(f"{artifact}: could not read artifact: {exc}")
            continue
        findings.extend(scan_bytes(data, str(artifact), needles))
    return findings


def version(
    command: Sequence[str], env: dict[str, str], *, cwd: Path = ROOT
) -> str:
    output = run(command, cwd=cwd, env=env, capture=True).splitlines()
    return output[0] if output else "unavailable"


def submodule_gitlinks(repo: Path) -> dict[str, str]:
    output = git(repo, "submodule", "status", "--recursive", capture=True)
    gitlinks = {}
    for line in output.splitlines():
        fields = line[1:].split()
        if len(fields) >= 2:
            gitlinks[fields[1]] = fields[0]
    return gitlinks


def rust_provenance(env: dict[str, str]) -> dict[str, str]:
    rust = ROOT / "DYNAM-O_rs" / "rust"
    verbose = run(("rustc", "-vV"), cwd=rust, env=env, capture=True)
    fields = {
        key.strip(): value.strip()
        for line in verbose.splitlines()
        if ":" in line
        for key, value in (line.split(":", 1),)
    }
    toolchain = "unavailable"
    if shutil.which("rustup"):
        active = run(
            ("rustup", "show", "active-toolchain"),
            cwd=rust,
            env=env,
            capture=True,
        )
        if active:
            toolchain = active.split()[0]
    return {
        "cargo": version(("cargo", "--version"), env, cwd=rust),
        "rustc": version(("rustc", "--version"), env, cwd=rust),
        "toolchain": toolchain,
        "host": fields.get("host", "unavailable"),
    }


def matlab_provenance(matlab: Path, env: dict[str, str]) -> dict[str, str]:
    command = (
        "fprintf('DYNAMO_MATLAB_VERSION=%s\\n',version);"
        "cfg=mex.getCompilerConfigurations('C','Selected');"
        "if isempty(cfg),"
        "fprintf('DYNAMO_MEX_COMPILER=unavailable\\n');"
        "else,"
        "fprintf('DYNAMO_MEX_COMPILER=%s|%s|%s\\n',"
        "cfg(1).Name,cfg(1).Version,cfg(1).Manufacturer);"
        "end"
    )
    output = run((str(matlab), "-batch", command), env=env, capture=True)
    values = {}
    for line in output.splitlines():
        if line.startswith("DYNAMO_MATLAB_VERSION="):
            values["version"] = line.split("=", 1)[1]
        elif line.startswith("DYNAMO_MEX_COMPILER="):
            values["mex_c_compiler"] = line.split("=", 1)[1]
    return {
        "version": values.get("version", "unavailable"),
        "mex_c_compiler": values.get("mex_c_compiler", "unavailable"),
    }


def write_manifest(
    toolbox_sha: str,
    shas: dict[str, str],
    gitlinks: dict[str, dict[str, str]],
    artifacts: Sequence[Path],
    internal_validation_artifacts: Sequence[Path],
    byte_scan_only_artifacts: Sequence[Path],
    env: dict[str, str],
    venv: Path,
    matlab: Path,
) -> Path:
    python, _ = venv_commands(venv)
    manifest = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "orchestrator": {
            "repository": "DYNAM-O_toolbox",
            "sha": toolbox_sha,
        },
        "repositories": shas,
        "repository_origins": CANONICAL_REPOSITORY_URLS,
        "submodule_gitlinks": gitlinks,
        "target": {
            "os": sys.platform,
            "architecture": platform.machine(),
            "rust": rust_provenance(env),
        },
        "tools": {
            "python": version(
                (str(python), "-c", "import platform; print(platform.python_version())"),
                env,
            ),
            "maturin": version((str(python), "-m", "maturin", "--version"), env),
            "matlab": matlab_provenance(matlab, env),
        },
        "artifacts": [str(path.relative_to(ROOT)) for path in artifacts],
        "internal_path_validation": [
            str(path.relative_to(ROOT)) for path in internal_validation_artifacts
        ],
        "cross_platform_byte_scan_only": [
            str(path.relative_to(ROOT)) for path in byte_scan_only_artifacts
        ],
    }
    path = ROOT / "release-build-manifest.json"
    path.write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    return path


def print_success_summary() -> None:
    if os.name == "nt":
        matlab_command = 'cd DYNAM-O; matlab -r "runDYNAMO(\'segment\')"'
        activate_command = r"DYNAM-O_py\.venv\Scripts\Activate.ps1"
        cli = ROOT / "DYNAM-O_rs" / "rust" / "target" / "release" / "dynamo.exe"
        cli_command = f'& "{cli}" --help'
    else:
        matlab_command = 'cd DYNAM-O && matlab -r "runDYNAMO(\'segment\')"'
        activate_command = "source DYNAM-O_py/.venv/bin/activate"
        cli = ROOT / "DYNAM-O_rs" / "rust" / "target" / "release" / "dynamo"
        cli_command = f"{cli} --help"

    print(
        "\n[bootstrap] Bootstrap complete.\n"
        "\n"
        "Next steps — pick one:\n"
        "\n"
        "  MATLAB:\n"
        f"    {matlab_command}\n"
        "\n"
        "  Python (pydynamo):\n"
        f"    {activate_command}\n"
        "    python -c 'import pydynamo; print(pydynamo.__version__)'\n"
        "\n"
        "  Rust CLI (no MATLAB or Python needed):\n"
        f"    {cli_command}\n"
    )


def main() -> int:
    if len(sys.argv) > 1:
        if sys.argv[1:] == ["--help"]:
            print(
                "usage: release_build.py\n\n"
                "Build and privacy-check artifacts from the three "
                "bootstrap-synchronized master checkouts."
            )
            return 0
        print("usage: release_build.py", file=sys.stderr)
        return 2
    try:
        require_clean(ROOT)
        toolbox_sha = git(ROOT, "rev-parse", "HEAD", capture=True)
        missing = [name for name in REPOSITORIES if not (ROOT / name / ".git").exists()]
        if missing:
            raise RuntimeError(
                f"missing repositories: {', '.join(missing)}; run bootstrap first"
            )
        env = release_environment()
        shas = {name: validate_master(ROOT / name) for name in REPOSITORIES}
        gitlinks = {
            name: submodule_gitlinks(ROOT / name) for name in REPOSITORIES
        }
        venv, matlab = build_artifacts(env)
        current_artifacts = platform_artifacts(venv)
        internal_validation_artifacts = rust_internal_validation_artifacts()
        unexpected_artifacts = unexpected_current_platform_binaries(
            current_artifacts
        )
        if unexpected_artifacts:
            rendered = ", ".join(str(path) for path in unexpected_artifacts)
            raise RuntimeError(
                "unexpected current-platform native artifacts are outside the "
                f"release allowlist: {rendered}"
            )
        byte_scan_only_artifacts = other_platform_binaries(current_artifacts)
        artifacts = list(
            dict.fromkeys((*current_artifacts, *byte_scan_only_artifacts))
        )
        sensitive_paths = {
            str(ROOT),
            os.getcwd(),
            os.environ.get("PWD", ""),
            str(Path.home()),
            env.get("CARGO_HOME") or str(Path.home() / ".cargo"),
            env.get("RUSTUP_HOME") or str(Path.home() / ".rustup"),
            tempfile.gettempdir(),
        }
        findings = scan_artifacts(
            (*current_artifacts, *internal_validation_artifacts),
            sensitive_paths,
        )
        findings.extend(
            scan_artifact_bytes(byte_scan_only_artifacts, sensitive_paths)
        )
        if findings:
            print("[release] Privacy gate failed:", file=sys.stderr)
            for finding in findings:
                print(f"  - {finding}", file=sys.stderr)
            return 1
        manifest = write_manifest(
            toolbox_sha,
            shas,
            gitlinks,
            artifacts,
            internal_validation_artifacts,
            byte_scan_only_artifacts,
            env,
            venv,
            matlab,
        )
        manifest_findings = scan_artifacts([manifest], sensitive_paths)
        if manifest_findings:
            print("[release] Manifest privacy check failed:", file=sys.stderr)
            for finding in manifest_findings:
                print(f"  - {finding}", file=sys.stderr)
            return 1
        print(f"[release] Privacy gate passed for {len(artifacts)} artifact(s).")
        print(f"[release] Manifest: {manifest}")
        print_success_summary()
        return 0
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"[release] ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
