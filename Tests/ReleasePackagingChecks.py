#!/usr/bin/env python3
"""Exercise release packaging in a temporary workspace; no Xcode or signing needed.

Run: python3 Tests/ReleasePackagingChecks.py (requires zsh).
Only the copied script's absolute PlistBuddy path is redirected to a mock.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

SCRIPT = Path(__file__).resolve().parents[1] / "build-installer.sh"
MOCK = r'''
import json, os, plistlib, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
record = {"tool": name, "args": args}
def plist(path):
    return plistlib.loads(Path(path).read_bytes())
if name == "PlistBuddy":
    command = args[1].split()
    path = Path(args[2])
    data = plist(path)
    action, key = command[:2]
    key = key.lstrip(":")
    if action == "Print":
        if key not in data:
            sys.exit(1)
        print(data[key])
    else:
        if action == "Set" and key not in data:
            sys.exit(1)
        data[key] = command[-1]
        path.write_bytes(plistlib.dumps(data))
elif name == "xcodebuild":
    output = Path(args[args.index("-derivedDataPath") + 1]) / "Build/Products/Release/Mio.app/Contents/Info.plist"
    output.parent.mkdir(parents=True)
    # Deliberately ignore overrides: the script must enforce actual bundle values.
    output.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7"}))
elif name == "codesign":
    record["plist"] = plist(Path(args[-1]) / "Contents/Info.plist")
elif name in ("hdiutil", "pkgbuild", "productbuild"):
    if name == "hdiutil":
        root = Path(args[args.index("-srcfolder") + 1])
        record["plist"] = plist(root / "Mio.app/Contents/Info.plist")
    elif name == "pkgbuild":
        root = Path(args[args.index("--root") + 1])
        record["plist"] = plist(root / "Mio.app/Contents/Info.plist")
    else:
        record["xml"] = Path(args[args.index("--distribution") + 1]).read_text()
    Path(args[-1]).touch()
else:
    raise RuntimeError("Unexpected tool: " + name)
with open(os.environ["MOCK_LOG"], "a") as log:
    log.write(json.dumps(record) + "\n")
'''


@unittest.skipUnless(shutil.which("zsh"), "zsh is required")
class ReleasePackagingChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="Mio-release-checks-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "mock-bin"
        self.bin.mkdir()
        mock = self.bin / "mock"
        mock.write_text("#!" + sys.executable + "\n" + MOCK)
        mock.chmod(0o755)
        for name in ("PlistBuddy", "xcodebuild", "codesign", "hdiutil", "pkgbuild", "productbuild"):
            (self.bin / name).symlink_to(mock)
        # No production test hook or host executable is changed.
        source = SCRIPT.read_text().replace("/usr/libexec/PlistBuddy", '"' + str(self.bin / "PlistBuddy") + '"')
        self.script = self.root / "build-installer.sh"
        self.script.write_text(source)
        self.info = self.root / "build/Mio.app/Contents/Info.plist"
        self.seed()
        self.env = {key: value for key, value in os.environ.items() if key not in (
            "VERSION", "BUILD_NUMBER", "SKIP_BUILD", "CODESIGN_IDENTITY", "PKG_IDENTITY", "NOTARY_PROFILE"
        )}
        self.env.update(PATH=str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
                        MOCK_LOG=str(self.root / "calls.jsonl"), TMPDIR=str(self.root))

    def seed(self, version="0.1.0", build="7"):
        self.info.parent.mkdir(parents=True, exist_ok=True)
        data = {"CFBundleShortVersionString": version}
        if build is not None:
            data["CFBundleVersion"] = build
        self.info.write_bytes(plistlib.dumps(data))

    def run_script(self, **settings):
        result = subprocess.run(["zsh", str(self.script)], env=dict(self.env, **settings),
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def check_package(self, calls, release, numeric, build):
        for extension in ("dmg", "pkg"):
            self.assertTrue((self.root / "dist" / ("Mio-" + release + "." + extension)).is_file())
        for call in calls:
            if "plist" in call:
                self.assertEqual(call["plist"]["CFBundleShortVersionString"], numeric)
                self.assertEqual(call["plist"]["CFBundleVersion"], build)
        pkg = next(call for call in calls if call["tool"] == "pkgbuild")
        self.assertEqual(pkg["args"][pkg["args"].index("--version") + 1], numeric)
        dmg = next(call for call in calls if call["tool"] == "hdiutil")
        self.assertEqual(dmg["args"][dmg["args"].index("-volname") + 1], "Mio " + release)
        product = next(call for call in calls if call["tool"] == "productbuild")
        xml = ET.fromstring(product["xml"])
        self.assertEqual(xml.findtext("title"), "Mio " + release)
        self.assertEqual(xml.find("pkg-ref").attrib["version"], numeric)
        self.assertEqual(xml.find("options").attrib["hostArchitectures"], "arm64,x86_64")
        self.assertEqual([call["tool"] for call in calls if call["tool"] != "PlistBuddy"][-5:],
                         ["codesign", "codesign", "hdiutil", "pkgbuild", "productbuild"])

    def test_build_normalizes_release_and_updates_metadata_before_signing(self):
        calls = self.run_script(VERSION="v1.2.3-beta.1+metadata", BUILD_NUMBER="42")
        self.check_package(calls, "1.2.3-beta.1+metadata", "1.2.3", "42")
        args = next(call["args"] for call in calls if call["tool"] == "xcodebuild")
        for setting in ("MARKETING_VERSION=1.2.3", "CURRENT_PROJECT_VERSION=42", "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO"):
            self.assertIn(setting, args)
        sign = next(call for call in calls if call["tool"] == "codesign")
        self.assertEqual(sign["args"][sign["args"].index("--sign") + 1], "-")

    def test_skip_build_still_applies_both_overrides(self):
        calls = self.run_script(SKIP_BUILD="1", VERSION="2.3.4-rc.2", BUILD_NUMBER="9.2.1")
        self.check_package(calls, "2.3.4-rc.2", "2.3.4", "9.2.1")
        self.assertNotIn("xcodebuild", [call["tool"] for call in calls])

    def test_skip_build_preserves_unspecified_versions(self):
        self.seed("3.4.5", "12")
        calls = self.run_script(SKIP_BUILD="1")
        self.check_package(calls, "3.4.5", "3.4.5", "12")

    def test_skip_build_preserves_legacy_numeric_app_version(self):
        self.seed("1.0", "3")
        calls = self.run_script(SKIP_BUILD="1")
        self.check_package(calls, "1.0", "1.0", "3")

    def test_build_preserves_project_defaults(self):
        calls = self.run_script()
        self.check_package(calls, "0.1.0", "0.1.0", "7")
        args = next(call["args"] for call in calls if call["tool"] == "xcodebuild")
        self.assertFalse(any(arg.startswith(("MARKETING_VERSION=", "CURRENT_PROJECT_VERSION=")) for arg in args))

    def test_missing_build_number_defaults_to_one(self):
        self.seed(build=None)
        calls = self.run_script(SKIP_BUILD="1", VERSION="1.0.0")
        self.check_package(calls, "1.0.0", "1.0.0", "1")

    def test_version_override_preserves_existing_build(self):
        calls = self.run_script(SKIP_BUILD="1", VERSION="1.2.3+build.8")
        self.check_package(calls, "1.2.3+build.8", "1.2.3", "7")

    def test_build_override_preserves_existing_version_and_identity_signing(self):
        calls = self.run_script(SKIP_BUILD="1", BUILD_NUMBER="42", CODESIGN_IDENTITY="Test Identity")
        self.check_package(calls, "0.1.0", "0.1.0", "42")
        sign = next(call for call in calls if call["tool"] == "codesign")
        self.assertEqual(sign["args"][sign["args"].index("--sign") + 1], "Test Identity")
        self.assertIn("--timestamp", sign["args"])

    def test_invalid_inputs_do_not_touch_build_or_dist(self):
        marker = self.root / "dist/keep.dmg"
        marker.parent.mkdir()
        marker.write_text("preserve")
        original = self.info.read_bytes()
        bad_versions = ("", "v", "1.2", "01.2.3", "1/2/3", "1.2.3-", "1.2.3+", "1.2.3-a..b",
                        "1.2.3+<xml>", "1.2.3\n", "1.2.3/../../escape", '1.2.3\"', "1.2.3;touch pwn")
        bad_builds = ("", "-1", "1.2.3.4", "1/2", "1.2a", "1\n", '1\"', "1;touch pwn")
        cases = [("VERSION", value) for value in bad_versions] + [("BUILD_NUMBER", value) for value in bad_builds]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                result = subprocess.run(["zsh", str(self.script)], env=dict(self.env, **{key: value}),
                                        text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("无效 " + key, result.stderr)
                self.assertEqual(self.info.read_bytes(), original)
                self.assertEqual(marker.read_text(), "preserve")
                self.assertFalse((self.root / "calls.jsonl").exists())
                self.assertFalse((self.root / "build/xcodebuild.log").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
