import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import call, patch

from scripts.release_build import (
    MEX_WRAPPERS,
    UNIT_SEPARATOR,
    cargo_environment,
    cargo_target_directory,
    dynamo_rlib_artifacts,
    other_platform_binaries,
    platform_artifacts,
    require_absent_artifact,
    release_environment,
    remap_flags,
    remove_stale_artifact,
    require_fresh_artifact,
    run,
    rust_internal_validation_artifacts,
    scan_artifact_bytes,
    submodule_gitlinks,
    unexpected_current_platform_binaries,
    validate_master,
)


class ReleaseBuildTests(unittest.TestCase):
    @patch("scripts.release_build.subprocess.run")
    def test_run_preserves_leading_submodule_status_marker(self, subprocess_run):
        subprocess_run.return_value = subprocess.CompletedProcess(
            args=("git",),
            returncode=0,
            stdout=" 0123456789abcdef dependency\n",
        )

        output = run(("git",), capture=True)

        self.assertEqual(output, " 0123456789abcdef dependency")

    @patch("scripts.release_build.require_clean")
    @patch("scripts.release_build.git")
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

    @patch("scripts.release_build.require_clean")
    @patch("scripts.release_build.git")
    def test_validate_master_rejects_non_master_branch(self, git, _require_clean):
        git.side_effect = (
            "https://github.com/preraulab/DYNAM-O.git",
            "feature",
        )
        with self.assertRaisesRegex(RuntimeError, "not master"):
            validate_master(Path("/workspace/DYNAM-O"))
        self.assertEqual(git.call_count, 2)

    @patch("scripts.release_build.require_clean")
    @patch(
        "scripts.release_build.git",
        return_value="https://github.com/someone/DYNAM-O.git",
    )
    def test_validate_master_rejects_noncanonical_origin(
        self, _git, _require_clean
    ):
        with self.assertRaisesRegex(RuntimeError, "expected preraulab/DYNAM-O"):
            validate_master(Path("/workspace/DYNAM-O"))

    @patch("scripts.release_build.require_clean")
    @patch("scripts.release_build.git")
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

    @patch("scripts.release_build.require_clean")
    @patch("scripts.release_build.git")
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

    @patch("scripts.release_build.git")
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
            unexpected = mex_dir / "unexpected.mexmaca64"
            unexpected.write_bytes(b"CURRENT")

            with patch("scripts.release_build.ROOT", root), patch(
                "scripts.release_build.sys.platform", "darwin"
            ), patch("scripts.release_build.platform.machine", return_value="arm64"):
                byte_scan_only = other_platform_binaries([current])
                unexpected_current = unexpected_current_platform_binaries([current])

            self.assertEqual(byte_scan_only, [other])
            self.assertEqual(unexpected_current, [unexpected])
            self.assertTrue(scan_artifact_bytes(byte_scan_only, []))

    def test_remap_flags_cover_raw_and_physical_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            physical = root / "physical"
            physical.mkdir()
            alias = root / "alias"
            alias.symlink_to(physical, target_is_directory=True)
            cargo_home = root / "not-created-cargo-home"
            environment = {
                "PWD": str(alias),
                "CARGO_HOME": str(cargo_home),
            }

            flags = remap_flags(alias, environment)
            values = flags.split(UNIT_SEPARATOR)
            self.assertIn(
                f"--remap-path-prefix={alias}=/workspace",
                values,
            )
            self.assertIn(
                f"--remap-path-prefix={physical.resolve()}=/workspace",
                values,
            )
            self.assertIn(
                f"--remap-path-prefix={cargo_home}=/build/cargo",
                values,
            )
            self.assertEqual(values[-1], "--remap-path-scope=all")
            self.assertNotIn(" ", UNIT_SEPARATOR)

    def test_remap_flags_put_more_specific_prefixes_last(self):
        home = Path("/Users/builder")
        root = home / "workspace"
        cargo_home = root / ".cargo"
        with patch.object(Path, "home", return_value=home):
            values = remap_flags(
                root,
                {"CARGO_HOME": str(cargo_home)},
            ).split(UNIT_SEPARATOR)

        home_flag = f"--remap-path-prefix={home}=/build/user"
        root_flag = f"--remap-path-prefix={root}=/workspace"
        cargo_flag = f"--remap-path-prefix={cargo_home}=/build/cargo"
        self.assertLess(values.index(home_flag), values.index(root_flag))
        self.assertLess(values.index(root_flag), values.index(cargo_flag))

    def test_release_environment_rejects_external_cargo_output_controls(self):
        for variable in ("CARGO_TARGET_DIR", "CARGO_BUILD_TARGET"):
            with self.subTest(variable=variable), patch.dict(
                os.environ, {variable: "/redirected"}, clear=True
            ):
                with self.assertRaisesRegex(RuntimeError, variable):
                    release_environment()

    def test_cargo_environment_pins_target_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            crate = Path(directory) / "crate"
            environment = {"EXAMPLE": "value"}

            controlled = cargo_environment(environment, crate)

            self.assertEqual(
                controlled["CARGO_TARGET_DIR"],
                str((crate / "target").resolve()),
            )
            self.assertNotIn("CARGO_TARGET_DIR", environment)

    @unittest.skipIf(os.name == "nt", "directory symlinks may require privileges")
    def test_cargo_target_directory_rejects_symlink_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            crate = root / "crate"
            external = root / "external"
            crate.mkdir()
            external.mkdir()
            (crate / "target").symlink_to(external, target_is_directory=True)

            with self.assertRaisesRegex(RuntimeError, "symlinked Cargo target"):
                cargo_target_directory(crate)

    def test_stale_artifact_is_removed_and_fresh_output_is_required(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "dynamo"
            artifact.write_bytes(b"STALE")

            remove_stale_artifact(artifact)

            self.assertFalse(artifact.exists())
            with self.assertRaisesRegex(RuntimeError, "configured Cargo build target"):
                require_fresh_artifact(artifact, "Cargo")
            artifact.write_bytes(b"FRESH")
            require_fresh_artifact(artifact, "Cargo")

    def test_forbidden_artifact_must_remain_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "libdynamo_rs.a"
            require_absent_artifact(artifact, "Cargo")
            artifact.write_bytes(b"ARCHIVE")

            with self.assertRaisesRegex(RuntimeError, "forbidden artifact"):
                require_absent_artifact(artifact, "Cargo")

    def test_internal_rust_validation_requires_rlib_and_rejects_staticlib(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            deps = root / "DYNAM-O_rs" / "rust" / "target" / "release" / "deps"
            deps.mkdir(parents=True)
            rlib = deps / "libdynamo_rs.rlib"
            rlib.write_bytes(b"RLIB")
            release = deps.parent
            import_library = release / "dynamo_rs.dll.lib"
            import_library.write_bytes(b"IMPORT")
            pdb = release / "dynamo.pdb"
            pdb.write_bytes(b"PDB")

            with patch("scripts.release_build.ROOT", root):
                self.assertEqual(
                    rust_internal_validation_artifacts(),
                    sorted((rlib, import_library, pdb)),
                )
                (deps / "libdynamo_rs.a").write_bytes(b"ARCHIVE")
                with self.assertRaisesRegex(RuntimeError, "forbidden artifact"):
                    rust_internal_validation_artifacts()
                (deps / "libdynamo_rs.a").unlink()
                (release / "dynamo_rs.lib").write_bytes(b"MSVC STATICLIB")
                with self.assertRaisesRegex(RuntimeError, "forbidden artifact"):
                    rust_internal_validation_artifacts()

    def test_dynamo_rlib_discovery_is_limited_to_first_party_name(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target"
            deps = target / "release" / "deps"
            deps.mkdir(parents=True)
            expected = deps / "libdynamo_rs-abc.rlib"
            expected.write_bytes(b"RLIB")
            (deps / "libdependency.rlib").write_bytes(b"DEPENDENCY")

            self.assertEqual(dynamo_rlib_artifacts(target), [expected])

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
            header = root / "DYNAM-O_rs" / "rust" / "include" / "dynamo_rs.h"
            header.parent.mkdir()
            header.write_text("/* generated */")

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

            with patch("scripts.release_build.ROOT", root), patch(
                "scripts.release_build.sys.platform", "linux"
            ):
                artifacts = platform_artifacts(venv)

            self.assertIn(native_module, artifacts)
            self.assertIn(python_filters / "filter_0.npy", artifacts)
            self.assertIn(header, artifacts)
            self.assertFalse(any("<expected-" in path.name for path in artifacts))


if __name__ == "__main__":
    unittest.main()
