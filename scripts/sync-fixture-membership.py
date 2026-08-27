#!/usr/bin/env python3
"""Keep project.pbxproj in step with the fixture tree.

osh-iosTests is a synchronized folder group, so Xcode adds every fixture file to
the test target's Resources phase individually — flattening seven folders' worth
of identically-named files onto each other and failing the build with
"Multiple commands produce ...". The tree is instead carried by a single folder
reference, which preserves its structure in the bundle, and each file is listed
as a membership exception so the synchronized group does not claim it as well.

A directory entry in membershipExceptions is ignored by Xcode; only file paths
work. Regenerating that list here is what keeps "add a fixture" from meaning
"hand-edit project.pbxproj".

Run directly, or let scripts/capture-fixtures.sh run it after a capture.
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(REPO, "osh-ios.xcodeproj", "project.pbxproj")
TESTS = os.path.join(REPO, "osh-iosTests")
FIXTURES = os.path.join(TESTS, "Fixtures")

BLOCK = re.compile(
    r"(membershipExceptions = \(\n)(?:\t\t\t\t[^\n]*\n)*?(\t\t\t\);)")


def fixture_files():
    return sorted(
        os.path.relpath(os.path.join(dirpath, name), TESTS)
        for dirpath, _, names in os.walk(FIXTURES)
        for name in names
        if not name.startswith("."))


def main():
    if not os.path.isdir(FIXTURES):
        print(f"no fixture tree at {FIXTURES}", file=sys.stderr)
        return 1

    files = fixture_files()
    with open(PROJECT) as handle:
        text = handle.read()

    entries = "".join("\t\t\t\t%s,\n" % path for path in files)
    patched, count = BLOCK.subn(lambda m: m.group(1) + entries + m.group(2),
                                text, count=1)
    if count == 0:
        print("no membershipExceptions block found — project not updated",
              file=sys.stderr)
        return 1

    if patched == text:
        print(f"project.pbxproj already in step ({len(files)} fixture files)")
        return 0

    with open(PROJECT, "w") as handle:
        handle.write(patched)
    print(f"project.pbxproj updated: {len(files)} fixture files listed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
