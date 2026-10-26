"""Exercise legacy installation in a temporary tree, with launchctl replaced by a stub."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class CLIInstallTests(unittest.TestCase):
    def test_install_and_uninstall_preserve_special_paths(self):
        with tempfile.TemporaryDirectory(prefix="wheelflip-install-test-") as temporary:
            root = Path(temporary)
            shutil.copyfile(REPO / "Makefile", root / "Makefile")
            shutil.copytree(REPO / "launchd", root / "launchd")
            (root / "build").mkdir()
            (root / "build/wheelflip").write_bytes(b"test executable placeholder")

            stubs = root / "stubs"
            stubs.mkdir()
            launchctl = stubs / "launchctl"
            launchctl.write_text('#!/bin/sh\nprintf "%s\\0" "$@" >> "$WF_TEST_LAUNCH_LOG"\n')
            launchctl.chmod(0o700)
            env = os.environ.copy()
            env["PATH"] = str(stubs) + os.pathsep + env["PATH"]
            env["WF_TEST_LAUNCH_LOG"] = str(root / "launchctl-arguments")

            # Quotes and XML metacharacters must survive both the shell and plist serialization.
            prefix = root / "prefix with 'quotes\" & <xml> `touch injected`"
            plist = root / "login items with 'quotes\" & <xml>" / "wheelflip.plist"
            sentinel = root / "prefix"
            sentinel.write_text("unrelated file")
            command = ["make", "-o", "build", f"PREFIX={prefix}", f"PLIST={plist}"]

            subprocess.run(command + ["install"], cwd=root, env=env, check=True,
                           capture_output=True, text=True)
            binary = prefix / "bin/wheelflip"
            self.assertEqual(binary.read_bytes(), b"test executable placeholder")
            with plist.open("rb") as handle:
                installed = plistlib.load(handle)
            self.assertEqual(installed["ProgramArguments"], [str(binary)])
            self.assertIn(str(plist).encode(), (root / "launchctl-arguments").read_bytes().split(b"\0"))
            self.assertFalse((root / "injected").exists())

            subprocess.run(command + ["uninstall"], cwd=root, env=env, check=True,
                           capture_output=True, text=True)
            self.assertFalse(binary.exists())
            self.assertFalse(plist.exists())
            self.assertEqual(sentinel.read_text(), "unrelated file")
            self.assertFalse((root / "injected").exists())


if __name__ == "__main__":
    unittest.main()
