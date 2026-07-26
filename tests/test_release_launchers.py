import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
POWERSHELLS = list(
    dict.fromkeys(
        executable
        for name in ("powershell", "pwsh")
        if (executable := shutil.which(name))
    )
)


class ReleaseLauncherTests(unittest.TestCase):
    def test_posix_launcher_locates_python(self):
        result = subprocess.run(
            [str(ROOT / "scripts" / "release_build.sh"), "--help"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("usage: release_build.py", result.stdout)

    @unittest.skipUnless(POWERSHELLS, "PowerShell is not available")
    def test_powershell_launcher_locates_python(self):
        for powershell in POWERSHELLS:
            with self.subTest(powershell=powershell):
                result = subprocess.run(
                    [
                        powershell,
                        "-NoProfile",
                        "-File",
                        str(ROOT / "scripts" / "release_build.ps1"),
                        "-Help",
                    ],
                    cwd=ROOT,
                    check=True,
                    capture_output=True,
                    text=True,
                )
                self.assertIn("usage: release_build.py", result.stdout)


class PosixBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        shutil.copy2(ROOT / "bootstrap.sh", self.root / "bootstrap.sh")

        for name in ("DYNAM-O", "DYNAM-O_rs", "DYNAM-O_py"):
            (self.root / name / ".git").mkdir(parents=True)

        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        fake_git = fake_bin / "git"
        fake_git.write_text(
            """#!/bin/sh
printf '%s\n' "$*" >> "$GIT_LOG"
case "$*" in
    *" status --porcelain"*)
        if [ "${FAIL_GIT_STATUS:-0}" != "0" ]; then
            exit "$FAIL_GIT_STATUS"
        fi
        ;;
esac
case "$*" in
    *"DYNAM-O_rs remote get-url origin")
        printf 'https://github.com/%s/DYNAM-O_rs.git\n' "${REMOTE_OWNER:-preraulab}"
        ;;
    *"DYNAM-O_py remote get-url origin")
        printf 'https://github.com/%s/DYNAM-O_py.git\n' "${REMOTE_OWNER:-preraulab}"
        ;;
    *"-C DYNAM-O remote get-url origin")
        printf 'https://github.com/%s/DYNAM-O.git\n' "${REMOTE_OWNER:-preraulab}"
        ;;
    *" remote get-url origin")
        printf '%s\n' 'https://github.com/preraulab/DYNAM-O_toolbox.git'
        ;;
    *" rev-parse --is-inside-work-tree")
        printf '%s\n' 'true'
        ;;
    *" rev-parse HEAD")
        printf '%s\n' '0123456789abcdef0123456789abcdef01234567'
        ;;
    *" rev-parse origin/master")
        printf '%s\n' '0123456789abcdef0123456789abcdef01234567'
        ;;
esac
exit 0
""",
            encoding="utf-8",
        )
        fake_git.chmod(0o755)

        scripts = self.root / "scripts"
        scripts.mkdir()
        launcher = scripts / "release_build.sh"
        launcher.write_text(
            """#!/bin/sh
printf '%s\n' delegated > "$RELEASE_MARKER"
exit "${RELEASE_EXIT_CODE:-0}"
""",
            encoding="utf-8",
        )
        launcher.chmod(0o755)

        self.git_log = self.root / "git.log"
        self.release_marker = self.root / "release.marker"
        self.environment = os.environ.copy()
        self.environment.update(
            {
                "PATH": f"{fake_bin}{os.pathsep}{self.environment['PATH']}",
                "GIT_LOG": str(self.git_log),
                "RELEASE_MARKER": str(self.release_marker),
            }
        )

    def tearDown(self):
        self.temporary_directory.cleanup()

    def run_bootstrap(self, *arguments, **environment):
        run_environment = self.environment.copy()
        run_environment.update(environment)
        return subprocess.run(
            [str(self.root / "bootstrap.sh"), *arguments],
            cwd=self.root,
            env=run_environment,
            capture_output=True,
            text=True,
        )

    def test_noninteractive_default_syncs_without_building(self):
        result = self.run_bootstrap()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.release_marker.exists())
        self.assertIn("No compilers or native build tools were invoked", result.stdout)
        log = self.git_log.read_text(encoding="utf-8")
        self.assertEqual(log.count("fetch origin master --prune"), 3)
        self.assertEqual(
            log.count("submodule update --init --recursive --checkout"),
            3,
        )
        self.assertNotRegex(log, r"\b(cargo|matlab|maturin)\b")

    def test_yes_delegates_and_propagates_failure(self):
        result = self.run_bootstrap("--yes", RELEASE_EXIT_CODE="7")

        self.assertEqual(result.returncode, 7)
        self.assertEqual(
            self.release_marker.read_text(encoding="utf-8").strip(),
            "delegated",
        )

    def test_git_status_failure_is_not_treated_as_clean(self):
        result = self.run_bootstrap("--yes", FAIL_GIT_STATUS="9")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.release_marker.exists())
        self.assertIn("Could not inspect the working tree", result.stderr)

    def test_wrong_child_origin_is_rejected_before_update(self):
        result = self.run_bootstrap("--yes", REMOTE_OWNER="someone-else")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.release_marker.exists())
        self.assertIn("not the expected preraulab/DYNAM-O_rs", result.stderr)
        log = self.git_log.read_text(encoding="utf-8")
        self.assertNotIn("fetch origin master --prune", log)

    def test_existing_nonrepository_directory_is_rejected(self):
        (self.root / "DYNAM-O_rs" / ".git").rmdir()

        result = self.run_bootstrap("--yes")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.release_marker.exists())
        self.assertIn("exists but is not a Git checkout", result.stderr)
        log = self.git_log.read_text(encoding="utf-8")
        self.assertNotIn("fetch origin master --prune", log)

    def test_windows_bootstrap_uses_the_same_public_contract(self):
        script = (ROOT / "bootstrap.ps1").read_text(encoding="utf-8")

        self.assertIn("[switch]$Yes", script)
        self.assertNotIn("[switch]$RustOnly", script)
        self.assertNotIn("[switch]$Release", script)
        self.assertIn("'scripts\\release_build.ps1'", script)


if __name__ == "__main__":
    unittest.main()
