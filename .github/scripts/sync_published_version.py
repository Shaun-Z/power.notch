#!/usr/bin/env python3
"""Copy the version actually shipped in a Sparkle appcast into an Xcode project."""

from __future__ import annotations

import argparse
import re
import xml.etree.ElementTree as ET
from pathlib import Path

from stamp_version import stamp_pbxproj, validate_version


SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def version_key(version: str) -> tuple:
    match = re.fullmatch(r"(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?", version)
    if not match:
        raise ValueError(f"Cannot compare marketing version: {version}")
    major, minor, patch, prerelease = match.groups()
    identifiers = tuple(
        (0, int(part)) if part.isdigit() else (1, part)
        for part in (prerelease or "").split(".")
    )
    return int(major), int(minor), int(patch or 0), prerelease is None, identifiers


def published_build(appcast: Path, version: str) -> int:
    # Read the generated artifact, not preparation.outputs.build_number: that
    # output is intentionally empty when resuming an existing draft release.
    builds = {
        item.findtext(f"{SPARKLE}version", "").strip()
        for item in ET.parse(appcast).findall("./channel/item")
        if item.findtext(f"{SPARKLE}shortVersionString", "").strip() == version
    }
    if len(builds) != 1:
        raise ValueError(f"Expected one unambiguous published build for {version}")
    build = builds.pop()
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError(f"Invalid published build number: {build}")
    return int(build)


def published_version(appcast: Path) -> str:
    versions = {
        item.findtext(f"{SPARKLE}shortVersionString", "").strip()
        for item in ET.parse(appcast).findall("./channel/item")
    }
    if len(versions) != 1 or not all(versions):
        raise ValueError("Expected one published version in generated appcast")
    return versions.pop()


def sync_project(pbxproj: Path, appcast: Path, version: str) -> None:
    validate_version(version)
    target_key = version_key(version)
    build = published_build(appcast, version)
    text = pbxproj.read_text(encoding="utf-8")
    builds = re.findall(r"CURRENT_PROJECT_VERSION\s*=\s*([^;]+);", text)
    versions = re.findall(r"MARKETING_VERSION\s*=\s*([^;]+);", text)
    if not builds or not versions:
        raise ValueError("Project must contain marketing and build versions")
    if any(not re.fullmatch(r"[1-9][0-9]*", value.strip()) for value in builds):
        raise ValueError("Project build numbers must be positive integers")
    if max(int(value.strip()) for value in builds) > build:
        print(f"Preserving project build newer than published build {build}")
        return
    # dev can advance while a release builds. Preserve its future marketing
    # version while raising the build floor to the number already distributed.
    has_newer_version = any(version_key(value.strip().strip('"')) > target_key for value in versions)
    stamp_pbxproj(pbxproj, None if has_newer_version else version, str(build))
    print(f"Synced published build {build}; marketing version: {'preserved newer development version' if has_newer_version else version}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pbxproj", required=True, type=Path)
    parser.add_argument("--appcast", required=True, type=Path)
    parser.add_argument("--version", help="Expected release version; infer from the single-item nightly appcast if omitted")
    args = parser.parse_args()
    sync_project(args.pbxproj, args.appcast, args.version or published_version(args.appcast))


if __name__ == "__main__":
    main()
