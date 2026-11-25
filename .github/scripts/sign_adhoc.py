#!/usr/bin/env python3
"""Sign a staged macOS app inside out without an Apple account or certificate."""

from __future__ import annotations

import argparse
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
OWN_ENTITLEMENTS = {
    "com.powernotch.app": PROJECT_ROOT / "powerNotch/powerNotch.entitlements",
    "com.powernotch.app.PowerNotchXPCHelper": PROJECT_ROOT
    / "PowerNotchXPCHelper/PowerNotchXPCHelper.entitlements",
    "com.powernotch.app.PowerNotchWidgets": PROJECT_ROOT
    / "PowerNotchWidgetsExtension.entitlements",
}
BUNDLE_SUFFIXES = {".app", ".appex", ".xpc", ".framework", ".bundle"}
MACHO_MAGICS = {
    bytes.fromhex(magic)
    for magic in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )
}
# These capabilities require a provisioned identity, or are inappropriate for
# a release build. Keep functional permissions such as the widget's sandbox.
UNPROVISIONED_ENTITLEMENTS = {
    "application-identifier",
    "com.apple.application-identifier",
    "com.apple.developer.team-identifier",
    "com.apple.security.application-groups",
    "keychain-access-groups",
    "get-task-allow",
    "com.apple.security.get-task-allow",
}


def read_plist(path: Path) -> dict:
    with path.open("rb") as stream:
        return plistlib.load(stream)


def bundle_info(bundle: Path) -> tuple[Path, dict] | None:
    for relative in ("Contents/Info.plist", "Resources/Info.plist", "Info.plist"):
        path = bundle / relative
        if path.is_file():
            info = read_plist(path)
            if info.get("CFBundleExecutable"):
                return path, info
    return None


def is_macho(path: Path) -> bool:
    with path.open("rb") as stream:
        return stream.read(4) in MACHO_MAGICS


def discover_targets(app: Path) -> list[tuple[Path, dict | None]]:
    """Find real files only; framework symlinks must remain symlinks."""
    bundles = []
    binaries = []
    bundle_executables = set()
    for directory, _, filenames in os.walk(app, followlinks=False):
        bundle = Path(directory)
        if bundle.suffix in BUNDLE_SUFFIXES and (metadata := bundle_info(bundle)):
            _, info = metadata
            bundles.append((bundle, info))
            executable = info["CFBundleExecutable"]
            for relative in (Path("Contents/MacOS") / executable, Path(executable)):
                candidate = bundle / relative
                if candidate.is_file():
                    bundle_executables.add(candidate.resolve())
                    break
        for filename in filenames:
            path = bundle / filename
            if not path.is_symlink() and is_macho(path):
                binaries.append(path)
    targets = bundles + [(path, None) for path in binaries if path.resolve() not in bundle_executables]
    return sorted(targets, key=lambda entry: (-len(entry[0].parts), str(entry[0])))


def existing_entitlements(target: Path) -> dict:
    result = subprocess.run(
        ["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(target)],
        capture_output=True,
        check=False,
    )
    if not result.stdout.strip():
        return {}
    return plistlib.loads(result.stdout)


def release_entitlements(entitlements: dict) -> dict:
    return {key: value for key, value in entitlements.items() if key not in UNPROVISIONED_ENTITLEMENTS}


def sign_app(app: Path) -> None:
    if not app.is_dir() or app.is_symlink() or app.suffix != ".app":
        raise ValueError("Expected a staged .app directory")
    targets = discover_targets(app)
    identifiers = {info.get("CFBundleIdentifier") for _, info in targets if info}
    missing = OWN_ENTITLEMENTS.keys() - identifiers
    if missing:
        raise ValueError(f"Archive is missing required app components: {', '.join(sorted(missing))}")

    # Capture vendor helper permissions before re-signing any component.
    # Signing only the outer app (or using --deep to sign) loses these distinctions.
    plans = []
    for target, info in targets:
        identifier = info.get("CFBundleIdentifier") if info else None
        source = OWN_ENTITLEMENTS.get(identifier)
        entitlements = read_plist(source) if source else existing_entitlements(target)
        plans.append((target, identifier, release_entitlements(entitlements)))
        if identifier in OWN_ENTITLEMENTS:
            info_path, updated_info = bundle_info(target)
            # No team can own this App Group in an ad-hoc build. The app/widget
            # already skip shared storage when the key has no valid team prefix.
            updated_info.pop("PowerNotchAppGroup", None)
            with info_path.open("wb") as stream:
                plistlib.dump(updated_info, stream, sort_keys=False)
            for relative in ("Contents/embedded.provisionprofile", "embedded.mobileprovision"):
                (target / relative).unlink(missing_ok=True)

    with tempfile.TemporaryDirectory(prefix="powernotch-entitlements-") as directory:
        entitlements_path = Path(directory) / "entitlements.plist"
        for target, identifier, entitlements in plans:
            command = ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--options", "0"]
            if identifier:
                command.extend(["--identifier", identifier])
            if entitlements:
                with entitlements_path.open("wb") as stream:
                    plistlib.dump(entitlements, stream)
                command.extend(["--entitlements", str(entitlements_path), "--generate-entitlement-der"])
            command.append(str(target))
            subprocess.run(command, check=True)

    # --deep is appropriate for verification: fail the build if any nested
    # executable, resource seal, or framework layout is invalid.
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)],
        check=True,
    )
    details = subprocess.run(
        ["/usr/bin/codesign", "--display", "--verbose=4", str(app)],
        capture_output=True, text=True, check=True,
    )
    flags = next((line for line in details.stderr.splitlines() if line.startswith("CodeDirectory ")), "")
    if "Signature=adhoc" not in details.stderr or "runtime" in flags:
        raise ValueError("Expected ad-hoc signing without hardened-runtime library validation")
    print(f"Verified ad-hoc signatures for {len(plans)} code components in {app}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Staged powerNotch.app (modified in place)")
    args = parser.parse_args()
    sign_app(args.app.absolute())


if __name__ == "__main__":
    main()
