import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from scripts.privacy_gate import (
    _elf_findings,
    scan_artifacts,
    scan_bytes,
    sensitive_needles,
)


class PrivacyGateTests(unittest.TestCase):
    def scan_text(self, value, sensitive_paths=()):
        data = value.encode() + b"\0" + value.encode("utf-16-le")
        return scan_bytes(data, "fixture", sensitive_needles(sensitive_paths))

    def assert_encodings_found(self, findings, marker):
        for encoding in ("ASCII", "UTF-16LE"):
            with self.subTest(encoding=encoding):
                self.assertTrue(
                    any(f"{encoding} {marker}" in item for item in findings)
                )

    def test_accepts_clean_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "clean.bin"
            artifact.write_bytes(
                b"NATIVE\0/workspace/src/lib.rs\0/build/user/.cache"
            )
            self.assertEqual(scan_artifacts([artifact], []), [])

    def test_allows_binary_data_that_only_resembles_windows_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "binary-metadata.bin"
            drive_like = r"b:\:@^:"
            unc_like = "U" + "\\" * 3 + "\\".join(("c", "j", "q", "x", ""))
            artifact.write_bytes(
                b"\x96"
                + drive_like.encode()
                + b"\xd8\0"
                + drive_like.encode("utf-16-le")
                + b"\xff\0"
                + unc_like.encode()
                + b"\x7f\0"
                + unc_like.encode("utf-16-le")
                + b"\xff"
            )

            self.assertEqual(scan_artifacts([artifact], []), [])

    def test_generic_windows_path_requires_plausible_hierarchy(self):
        one_component = r"B:\9@^9"
        self.assertEqual(self.scan_text(one_component), [])
        self.assertEqual(self.scan_text(r"K:\b\q^"), [])

        findings = self.scan_text(one_component + r"\src")
        self.assert_encodings_found(findings, "absolute Windows path")

        exact_findings = self.scan_text(one_component, [one_component])
        self.assert_encodings_found(exact_findings, "path marker")

    def test_rejects_compact_windows_ci_path(self):
        path = r"D:\a\1\s"
        for value in (path, json.dumps({"path": path})):
            findings = self.scan_text(value)
            self.assert_encodings_found(findings, "absolute Windows path")

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

    def test_generic_unc_path_requires_plausible_hierarchy(self):
        low_evidence = (r"\\c\j\q\x", r"\\&O\BN_")
        for value in low_evidence:
            self.assertEqual(self.scan_text(value), [])

        findings = self.scan_text(r"\\server\share\src")
        self.assert_encodings_found(findings, "absolute Windows UNC")

        exact_findings = self.scan_text(low_evidence[0], [low_evidence[0]])
        self.assert_encodings_found(exact_findings, "path marker")

    def test_rejects_nested_unc_paths_with_short_root_components(self):
        paths = (r"\\server\x\project", r"\\s\share\project")
        for path in paths:
            for value in (path, json.dumps({"path": path})):
                findings = self.scan_text(value)
                self.assert_encodings_found(findings, "absolute Windows UNC")

    def test_scans_json_escaped_windows_paths(self):
        drive_path = r"D:\agent\_work\crate"
        unc_path = r"\\server\share\src"
        extended_unc_path = r"\\?\UNC\server\share\src"
        payload = json.dumps(
            {
                "drive": drive_path,
                "unc": unc_path,
                "extended_unc": extended_unc_path,
            }
        )
        findings = self.scan_text(payload)
        self.assert_encodings_found(findings, "absolute Windows path")
        for expected in (unc_path, extended_unc_path):
            serialized = repr(expected.replace("\\", "\\\\"))
            for encoding in ("ASCII", "UTF-16LE"):
                self.assertTrue(
                    any(
                        f"{encoding} absolute Windows UNC" in item
                        and serialized in item
                        for item in findings
                    )
                )

        exact_path = r"B:\9@^9"
        exact_payload = json.dumps({"path": exact_path})
        exact_findings = self.scan_text(exact_payload, [exact_path])
        self.assert_encodings_found(exact_findings, "path marker")

    def test_allows_json_escaped_relative_windows_path(self):
        relative = r"relative\directory\src\file.rs"
        self.assertEqual(self.scan_text(json.dumps({"path": relative})), [])

    def test_rejects_windows_unc_share_roots(self):
        for unc in (r"\\server\share", r"\\?\UNC\server\share"):
            for value in (unc, json.dumps({"path": unc})):
                findings = self.scan_text(value)
                self.assert_encodings_found(
                    findings, "absolute Windows UNC"
                )

    def test_rejects_extended_windows_unc_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "extended-unc.pdb"
            unc = r"\\?\UNC\server\share\project\src\lib.rs"
            prefixed = "path:" + unc
            artifact.write_bytes(
                prefixed.encode() + b"\0" + prefixed.encode("utf-16-le")
            )

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
