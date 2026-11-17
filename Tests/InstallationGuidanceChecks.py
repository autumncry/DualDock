#!/usr/bin/env python3
"""Exercise the release guard using isolated documentation and volume fixtures."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
GUARD = REPOSITORY / "script/check_installation_guidance.py"
DOCUMENTS = ("README.md", "README.en.md", "docs/installation.txt")


class InstallationGuidanceChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dualdock-installation-check-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for relative in DOCUMENTS:
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPOSITORY / relative, destination)
        self.volume = self.root / "volume"
        self.volume.mkdir()
        self.installation = self.volume / "安装说明.txt"
        shutil.copyfile(self.root / "docs/installation.txt", self.installation)

    def run_guard(self, volume=False):
        command = [sys.executable, str(GUARD), "--root", str(self.root)]
        if volume:
            command.extend(("--volume", str(self.volume)))
        return subprocess.run(command, capture_output=True, text=True)

    def assert_rejected(self, result, expected):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(expected, result.stderr)

    def test_current_documents_and_packaged_copy_pass(self):
        for volume in (False, True):
            with self.subTest(volume=volume):
                result = self.run_guard(volume)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_each_missing_document_fails(self):
        for relative in DOCUMENTS:
            with self.subTest(document=relative):
                document = self.root / relative
                contents = document.read_bytes()
                document.unlink()
                self.assert_rejected(self.run_guard(), relative)
                document.write_bytes(contents)

    def test_each_removed_open_anyway_step_fails(self):
        for relative in DOCUMENTS:
            with self.subTest(document=relative):
                document = self.root / relative
                contents = document.read_text()
                document.write_text(contents.replace("Open Anyway", ""))
                self.assert_rejected(self.run_guard(), relative)
                document.write_text(contents)

    def test_empty_marked_readme_section_fails(self):
        document = self.root / "README.en.md"
        contents = document.read_text()
        start = contents.index("<!-- first-launch-guidance:start -->")
        end = contents.index("<!-- first-launch-guidance:end -->")
        document.write_text(contents[:start] + contents[end:])
        self.assert_rejected(self.run_guard(), "README.en.md")

    def test_reversed_guidance_markers_fail(self):
        document = self.root / "README.en.md"
        contents = document.read_text()
        contents = contents.replace("first-launch-guidance:start", "first-launch-guidance:temporary")
        contents = contents.replace("first-launch-guidance:end", "first-launch-guidance:start")
        document.write_text(contents.replace("first-launch-guidance:temporary", "first-launch-guidance:end"))
        self.assert_rejected(self.run_guard(), "README.en.md")

    def test_missing_packaged_instructions_fail(self):
        self.installation.unlink()
        self.assert_rejected(self.run_guard(volume=True), "安装说明.txt")

    def test_stale_packaged_instructions_fail(self):
        self.installation.write_text("Old installation instructions\n")
        self.assert_rejected(self.run_guard(volume=True), "安装说明.txt")

    def test_packaged_symlink_fails(self):
        self.installation.unlink()
        self.installation.symlink_to(self.root / "docs/installation.txt")
        self.assert_rejected(self.run_guard(volume=True), "安装说明.txt")


if __name__ == "__main__":
    unittest.main()
