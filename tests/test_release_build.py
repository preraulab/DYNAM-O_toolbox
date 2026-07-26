import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from release_build import MEX_WRAPPERS, UNIT_SEPARATOR, platform_artifacts, remap_flags


class ReleaseBuildTests(unittest.TestCase):
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
