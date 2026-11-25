#!/usr/bin/env python3
"""Exercise ad-hoc signing, including native nested-code verification on macOS."""

import importlib.util
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "sign_adhoc.py"
SPEC = importlib.util.spec_from_file_location("sign_adhoc", SCRIPT)
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)


class AdHocSigningTests(unittest.TestCase):
    def test_drops_provisioned_and_debug_permissions_but_keeps_sandbox_permissions(self):
        source = {
            key: ["TEAM.example"] if "groups" in key else "TEAM"
            for key in signing.UNPROVISIONED_ENTITLEMENTS
        }
        source.update({
            "com.apple.security.app-sandbox": True,
            "com.apple.security.network.client": True,
            "com.apple.security.temporary-exception.files.home-relative-path.read-only": [
                "/Library/Application Support/powerNotch/widget/"
            ],
        })
        self.assertEqual(signing.release_entitlements(source), {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.network.client": True,
            "com.apple.security.temporary-exception.files.home-relative-path.read-only": [
                "/Library/Application Support/powerNotch/widget/"
            ],
        })

    def test_widget_source_entitlements_keep_only_the_narrow_snapshot_exception(self):
        source = signing.read_plist(signing.OWN_ENTITLEMENTS["com.powernotch.app.PowerNotchWidgets"])
        result = signing.release_entitlements(source)
        self.assertEqual(result, {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.temporary-exception.files.home-relative-path.read-only": [
                "/Library/Application Support/powerNotch/widget/"
            ],
        })

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS codesign and clang")
    def test_signs_nested_code_preserves_symlinks_and_rejects_tampering(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "fixture"
            subprocess.run(
                ["/usr/bin/clang", "-x", "c", "-", "-o", str(executable)],
                input="int main(void) { return 0; }", text=True, check=True,
            )

            def make_bundle(path, identifier, package_type):
                contents = path / "Contents"
                (contents / "MacOS").mkdir(parents=True)
                shutil.copy2(executable, contents / "MacOS/Fixture")
                info = {
                    "CFBundleIdentifier": identifier,
                    "CFBundleExecutable": "Fixture",
                    "CFBundlePackageType": package_type,
                    "CFBundleVersion": "1",
                    "PowerNotchAppGroup": "TEAM.com.powernotch.app",
                }
                with (contents / "Info.plist").open("wb") as stream:
                    plistlib.dump(info, stream)
                return path

            app = make_bundle(root / "powerNotch.app", "com.powernotch.app", "APPL")
            helper = make_bundle(
                app / "Contents/XPCServices/PowerNotchXPCHelper.xpc",
                "com.powernotch.app.PowerNotchXPCHelper", "XPC!",
            )
            widget = make_bundle(
                app / "Contents/PlugIns/PowerNotchWidgets.appex",
                "com.powernotch.app.PowerNotchWidgets", "XPC!",
            )
            framework = app / "Contents/Frameworks/Fixture.framework"
            version = framework / "Versions/A"
            (version / "Resources").mkdir(parents=True)
            subprocess.run(
                ["/usr/bin/clang", "-dynamiclib", "-x", "c", "-", "-o", str(version / "Fixture")],
                input="int fixture(void) { return 1; }", text=True, check=True,
            )
            with (version / "Resources/Info.plist").open("wb") as stream:
                plistlib.dump({
                    "CFBundleIdentifier": "org.example.fixture",
                    "CFBundleExecutable": "Fixture",
                    "CFBundlePackageType": "FMWK",
                    "CFBundleVersion": "1",
                }, stream)
            (framework / "Versions/Current").symlink_to("A")
            (framework / "Fixture").symlink_to("Versions/Current/Fixture")
            (framework / "Resources").symlink_to("Versions/Current/Resources")

            vendor_helper = make_bundle(
                version / "XPCServices/Downloader.xpc", "org.example.downloader", "XPC!",
            )
            vendor_entitlements = root / "vendor-entitlements.plist"
            vendor_entitlements.write_bytes(plistlib.dumps({
                "com.apple.security.app-sandbox": True,
                "com.apple.security.network.client": True,
            }))
            subprocess.run([
                "/usr/bin/codesign", "--sign", "-", "--force",
                "--entitlements", str(vendor_entitlements), str(vendor_helper),
            ], check=True)
            (app / "Contents/Resources").mkdir()
            resource = app / "Contents/Resources/resource.txt"
            resource.write_text("original")

            own_permissions = {
                "com.powernotch.app": {"com.apple.security.device.camera": True},
                "com.powernotch.app.PowerNotchXPCHelper": {"com.apple.security.app-sandbox": False},
                "com.powernotch.app.PowerNotchWidgets": {
                    "com.apple.security.app-sandbox": True,
                    "com.apple.security.temporary-exception.files.home-relative-path.read-only": [
                        "/Library/Application Support/powerNotch/widget/"
                    ],
                },
            }
            fixtures = {}
            for index, (identifier, permissions) in enumerate(own_permissions.items()):
                path = root / f"own-entitlements-{index}.plist"
                path.write_bytes(plistlib.dumps({
                    **permissions,
                    "com.apple.security.application-groups": ["TEAM.com.powernotch.app"],
                }))
                fixtures[identifier] = path
            with patch.dict(signing.OWN_ENTITLEMENTS, fixtures, clear=True):
                signing.sign_app(app)

            self.assertTrue((framework / "Fixture").is_symlink())
            self.assertTrue((framework / "Resources").is_symlink())
            self.assertTrue((framework / "Versions/Current").is_symlink())
            for bundle in (app, helper, widget):
                self.assertNotIn("PowerNotchAppGroup", signing.bundle_info(bundle)[1])
                self.assertNotIn("com.apple.security.application-groups", signing.existing_entitlements(bundle))
            self.assertTrue(signing.existing_entitlements(app)["com.apple.security.device.camera"])
            self.assertTrue(signing.existing_entitlements(widget)["com.apple.security.app-sandbox"])
            self.assertEqual(
                signing.existing_entitlements(widget)[
                    "com.apple.security.temporary-exception.files.home-relative-path.read-only"
                ],
                ["/Library/Application Support/powerNotch/widget/"],
            )
            self.assertTrue(signing.existing_entitlements(vendor_helper)["com.apple.security.network.client"])

            resource.write_text("modified after signing")
            result = subprocess.run(
                ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
