import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import call, patch

from release_build import (
    MEX_WRAPPERS,
    UNIT_SEPARATOR,
    other_platform_binaries,
    platform_artifacts,
    remap_flags,
    run,
    scan_artifact_bytes,
    submodule_gitlinks,
    validate_master,
)


class ReleaseBuildTests(unittest.TestCase):
    @patch("release_build.subprocess.run")
    def test_run_preserves_leading_submodule_status_marker(self, subprocess_run):
        subprocess_run.return_value = subprocess.CompletedProcess(
            args=("git",),
            returncode=0,
            stdout=" 0123456789abcdef dependency\n",
        )

        output = run(("git",), capture=True)

        self.assertEqual(output, " 0123456789abcdef dependency")

    @patch("release_build.require_clean")
    @patch("release_build.git")
    def test_validate_master_uses_read_only_git_commands(self, git, require_clean):
        git.side_effect = (
            "https://github.com/preraulab/DYNAM-O.git",
            "master",
            "0123456789abcdef",
            "0123456789abcdef\trefs/heads/master",
            " abcdef0123456789 dependency",
        )
        repository = Path("/workspace/DYNAM-O")

        self.assertEqual(validate_master(repository), "0123456789abcdef")
        self.assertEqual(require_clean.call_count, 2)
        self.assertEqual(
            git.call_args_list,
            [
                call(repository, "remote", "get-url", "origin", capture=True),
                call(repository, "symbolic-ref", "--short", "HEAD", capture=True),
                call(repository, "rev-parse", "HEAD", capture=True),
                call(
                    repository,
                    "ls-remote",
                    "--exit-code",
                    "origin",
                    "refs/heads/master",
                    capture=True,
                ),
                call(
                    repository,
                    "submodule",
                    "status",
                    "--recursive",
                    capture=True,
                ),
            ],
        )

    @patch("release_build.require_clean")
    @patch("release_build.git")
    def test_validate_master_rejects_non_master_branch(self, git, _require_clean):
        git.side_effect = (
            "https://github.com/preraulab/DYNAM-O.git",
            "feature",
        )
        with self.assertRaisesRegex(RuntimeError, "not master"):
            validate_master(Path("/workspace/DYNAM-O"))
        self.assertEqual(git.call_count, 2)

    @patch("release_build.require_clean")
    @patch("release_build.git", return_value="https://github.com/someone/DYNAM-O.git")
    def test_validate_master_rejects_noncanonical_origin(
        self, _git, _require_clean
    ):
        with self.assertRaisesRegex(RuntimeError, "expected preraulab/DYNAM-O"):
            validate_master(Path("/workspace/DYNAM-O"))

    @patch("release_build.require_clean")
    @patch("release_build.git")
    def test_validate_master_rejects_head_not_at_live_origin(
        self, git, _require_clean
    ):
        git.side_effect = (
            "https://github.com/preraulab/DYNAM-O.git",
            "master",
            "local-head",
            "remote-head\trefs/heads/master",
        )
        with self.assertRaisesRegex(RuntimeError, "current origin/master"):
            validate_master(Path("/workspace/DYNAM-O"))

    @patch("release_build.require_clean")
    @patch("release_build.git")
    def test_validate_master_rejects_submodule_markers(self, git, _require_clean):
        for marker in ("-", "+", "U"):
            with self.subTest(marker=marker):
                git.reset_mock()
                git.side_effect = (
                    "https://github.com/preraulab/DYNAM-O.git",
                    "master",
                    "same-head",
                    "same-head\trefs/heads/master",
                    f"{marker}abcdef dependency",
                )
                with self.assertRaisesRegex(RuntimeError, "recorded gitlinks"):
                    validate_master(Path("/workspace/DYNAM-O"))

    @patch("release_build.git")
    def test_submodule_gitlinks_preserves_first_sha(self, git):
        git.return_value = (
            " 0123456789abcdef first\n"
            " fedcba9876543210 second"
        )

        self.assertEqual(
            submodule_gitlinks(Path("/workspace/DYNAM-O")),
            {
                "first": "0123456789abcdef",
                "second": "fedcba9876543210",
            },
        )

    def test_other_platform_binaries_receive_a_path_byte_scan(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mex_dir = root / "DYNAM-O" / "rust_bridge"
            mex_dir.mkdir(parents=True)
            current = mex_dir / "current.mexmaca64"
            current.write_bytes(b"CURRENT")
            other = mex_dir / "old.mexw64"
            other.write_bytes(b"C:\\Users\\builder\\source")

            with patch("release_build.ROOT", root):
                byte_scan_only = other_platform_binaries([current])

            self.assertEqual(byte_scan_only, [other])
            self.assertTrue(scan_artifact_bytes(byte_scan_only, []))

    def test_remap_flags_use_encoded_separator_and_physical_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            flags = remap_flags(root, os.environ)
            values = flags.split(UNIT_SEPARATOR)
            self.assertIn(
                f"--remap-path-prefix={root}=/workspace",
                values,
            )
            self.assertEqual(
                values[-2],
                f"--remap-path-prefix={root}=/workspace",
            )
            self.assertEqual(values[-1], "--remap-path-scope=object")
            self.assertNotIn(" ", UNIT_SEPARATOR)

    def test_discovers_packaged_native_module_and_runtime_filters(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mex_dir = root / "DYNAM-O" / "rust_bridge"
            mex_dir.mkdir(parents=True)
            for wrapper in MEX_WRAPPERS:
                (mex_dir / f"{wrapper}.mexa64").write_bytes(b"\x7fELF")
            (mex_dir / "libdynamo_rs.so").write_bytes(b"ELF")
            matlab_filters = mex_dir / "data_matlab_filters"
            matlab_filters.mkdir()
            source_filters = root / "DYNAM-O_rs" / "data_matlab_filters"
            source_filters.mkdir(parents=True)
            for index in range(42):
                name = f"filter_{index}.npy"
                (source_filters / name).write_bytes(b"NUMPY")
                (matlab_filters / name).write_bytes(b"NUMPY")

            target = root / "DYNAM-O_rs" / "rust" / "target" / "release"
            target.mkdir(parents=True)
            (target / "dynamo").write_bytes(b"CLI")

            venv = root / "DYNAM-O_py" / ".venv"
            packages = venv / "lib" / "python3.9" / "site-packages"
            dynamo_package = packages / "dynamo_rs"
            dynamo_package.mkdir(parents=True)
            native_module = dynamo_package / "dynamo_rs.abi3.so"
            native_module.write_bytes(b"NATIVE")
            python_filters = dynamo_package / "data_matlab_filters"
            python_filters.mkdir()
            for index in range(42):
                (python_filters / f"filter_{index}.npy").write_bytes(b"NUMPY")
            multitaper = packages / "multitaper_rs.abi3.so"
            multitaper.write_bytes(b"NATIVE")
            for distribution in ("dynamo_rs", "multitaper_rs"):
                sbom = (
                    packages
                    / f"{distribution}-0.1.0.dist-info"
                    / "sboms"
                    / f"{distribution}.json"
                )
                sbom.parent.mkdir(parents=True)
                sbom.write_text("{}")

            with patch("release_build.ROOT", root), patch(
                "release_build.sys.platform", "linux"
            ):
                artifacts = platform_artifacts(venv)

            self.assertIn(native_module, artifacts)
            self.assertIn(python_filters / "filter_0.npy", artifacts)
            self.assertFalse(any("<expected-" in path.name for path in artifacts))


if __name__ == "__main__":
    unittest.main()
