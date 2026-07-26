import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from scripts.privacy_gate import _elf_findings, scan_artifacts


class PrivacyGateTests(unittest.TestCase):
    def test_accepts_clean_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "clean.bin"
            artifact.write_bytes(
                b"NATIVE\0/workspace/src/lib.rs\0/build/user/.cache"
            )
            self.assertEqual(scan_artifacts([artifact], []), [])

    def test_rejects_ascii_and_utf16_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "leaky.dll"
            artifact.write_bytes(
                b"C:\\Users\\builder\\source"
                + "/Users/builder/source".encode("utf-16-le")
            )
            findings = scan_artifacts([artifact], [])
            self.assertTrue(any("ASCII" in finding for finding in findings))
            self.assertTrue(any("UTF-16LE" in finding for finding in findings))

    def test_rejects_non_userprofile_windows_absolute_path(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "leaky.pdb"
            artifact.write_bytes(
                b"RSDS"
                + b"D:\\agent\\_work\\crate\\src\\lib.rs"
                + "E:\\build\\crate.pdb".encode("utf-16-le")
            )
            findings = scan_artifacts([artifact], [])
            self.assertTrue(any("ASCII absolute Windows" in item for item in findings))
            self.assertTrue(any("UTF-16LE absolute Windows" in item for item in findings))

    def test_rejects_windows_unc_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "leaky.pdb"
            unc = r"\\server\private-share\project\src\lib.rs"
            artifact.write_bytes(unc.encode() + b"\0" + unc.encode("utf-16-le"))

            findings = scan_artifacts([artifact], [])

            self.assertTrue(any("ASCII absolute Windows UNC" in item for item in findings))
            self.assertTrue(
                any("UTF-16LE absolute Windows UNC" in item for item in findings)
            )

    def test_rejects_extended_windows_unc_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "extended-unc.pdb"
            unc = r"\\?\UNC\server\share\project\src\lib.rs"
            artifact.write_bytes(unc.encode() + b"\0" + unc.encode("utf-16-le"))

            findings = scan_artifacts([artifact], [])

            self.assertTrue(any("ASCII absolute Windows UNC" in item for item in findings))
            self.assertTrue(
                any("UTF-16LE absolute Windows UNC" in item for item in findings)
            )

    def test_rejects_generic_temporary_paths_but_allows_virtual_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            leaky = root / "leaky.bin"
            clean = root / "clean.bin"
            leaky.write_bytes(
                b"/tmp/private-build/src/lib.rs\0/var/tmp/other-build/src/lib.rs"
            )
            clean.write_bytes(b"/build/temporary/src/lib.rs")

            self.assertTrue(scan_artifacts([leaky], []))
            self.assertEqual(scan_artifacts([clean], []), [])

    def test_sensitive_path_covers_raw_and_resolved_aliases(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            physical = root / "physical"
            physical.mkdir()
            alias = root / "alias"
            alias.symlink_to(physical, target_is_directory=True)
            artifact = root / "leaky.bin"
            artifact.write_bytes(
                str(alias).encode() + b"\0" + str(physical.resolve()).encode()
            )

            findings = scan_artifacts([artifact], [str(alias)])

            self.assertTrue(any(str(alias) in item for item in findings))
            self.assertTrue(any(str(physical.resolve()) in item for item in findings))

    def test_allows_sanitized_file_uri(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "sbom.json"
            artifact.write_bytes(
                b'{"path":"file:///workspace/crate"}'
                + "file:///workspace/crate".encode("utf-16-le")
            )
            self.assertEqual(scan_artifacts([artifact], []), [])

    def test_scans_wheel_members(self):
        with tempfile.TemporaryDirectory() as directory:
            wheel = Path(directory) / "example.whl"
            with zipfile.ZipFile(wheel, "w") as archive:
                archive.writestr(
                    "example.dist-info/sboms/example.json",
                    '{"path":"file:///home/builder/source"}',
                )
            self.assertTrue(scan_artifacts([wheel], []))

    @patch("scripts.privacy_gate._elf_findings")
    def test_structurally_inspects_native_wheel_members(self, elf_findings):
        with tempfile.TemporaryDirectory() as directory:
            wheel = Path(directory) / "example.whl"
            with zipfile.ZipFile(wheel, "w") as archive:
                archive.writestr("example/native.abi3.so", b"\x7fELF" + b"\0" * 64)
            elf_findings.side_effect = lambda path: [
                f"{path}: absolute ELF search path '/opt/private'"
            ]
            findings = scan_artifacts([wheel], [])
            self.assertTrue(
                any(
                    "example.whl!example/native.abi3.so" in finding
                    for finding in findings
                )
            )

    def test_rejects_unrecognized_native_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "placeholder.mexa64"
            artifact.write_bytes(b"not a native binary")
            findings = scan_artifacts([artifact], [])
            self.assertTrue(any("expected ELF native binary" in item for item in findings))

    def test_rejects_missing_artifact(self):
        findings = scan_artifacts([Path("/definitely/missing/artifact.so")], [])
        self.assertEqual(len(findings), 1)
        self.assertIn("expected artifact is missing", findings[0])

    @patch("scripts.privacy_gate.shutil.which", return_value="/usr/bin/readelf")
    @patch("scripts.privacy_gate._run_inspector")
    def test_rejects_absolute_elf_runpath(self, inspect, _which):
        inspect.return_value = (
            " 0x1 (NEEDED) Shared library: [libdynamo_rs.so]\n"
            " 0x1d (RUNPATH) Library runpath: [/home/builder/lib:$ORIGIN]\n",
            [],
        )
        findings = _elf_findings(Path("example.so"))
        self.assertEqual(
            findings,
            ["example.so: absolute ELF search path '/home/builder/lib'"],
        )


if __name__ == "__main__":
    unittest.main()
