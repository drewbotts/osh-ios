#!/bin/bash
#
# stamp-build-version.sh — write CFBundleVersion and CFBundleShortVersionString
# into a built bundle's Info.plist.
#
# Run as the last build phase of BOTH the app and the widget extension. It
# patches the *product's* Info.plist rather than setting a build setting,
# because CURRENT_PROJECT_VERSION is consumed while the plist is generated —
# long before any script phase could change it.
#
# The build number is the commit count, so it rises monotonically with history
# and never has to be remembered or bumped by hand. App Store Connect refuses a
# build number it has already seen, which is exactly the mistake this avoids.
#
# Both targets run the same script over the same repository, so the app and the
# extension get identical values by construction. That matters: App Store
# Connect rejects an upload whose extension version does not match its app's.
#
# Requires ENABLE_USER_SCRIPT_SANDBOXING = NO on the targets that run it —
# reading .git is exactly what the sandbox denies.

set -euo pipefail

PLIST="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
if [[ ! -f "$PLIST" ]]; then
  echo "warning: no Info.plist at $PLIST; build version not stamped"
  exit 0
fi

# Commit count, or 1 when there is no git, no repository, or no history —
# a source drop from a tarball still has to build.
BUILD_NUMBER=1
if command -v git > /dev/null 2>&1; then
  if COUNT="$(git -C "${SRCROOT:?}" rev-list --count HEAD 2> /dev/null)" \
     && [[ "$COUNT" =~ ^[0-9]+$ ]] && [[ "$COUNT" -gt 0 ]]; then
    BUILD_NUMBER="$COUNT"
  else
    echo "note: git gave no commit count; using build number $BUILD_NUMBER"
  fi
else
  echo "note: git unavailable; using build number $BUILD_NUMBER"
fi

PLISTBUDDY=/usr/libexec/PlistBuddy

# PlistBuddy exits 0 on some write failures — script sandboxing denying the
# build directory is one of them — so every write is read back. A version stamp
# that silently did nothing is worse than no stamp at all: the upload is
# rejected hours later for a duplicate build number.
set_key() {
  local key="$1" value="$2"
  "$PLISTBUDDY" -c "Set :$key $value" "$PLIST" > /dev/null 2>&1 \
    || "$PLISTBUDDY" -c "Add :$key string $value" "$PLIST" > /dev/null 2>&1 \
    || true

  local actual
  actual="$("$PLISTBUDDY" -c "Print :$key" "$PLIST" 2> /dev/null || true)"
  if [[ "$actual" != "$value" ]]; then
    echo "error: could not write $key to $PLIST (wanted '$value', found '${actual:-nothing}')."
    echo "error: if this is a sandbox denial, ENABLE_USER_SCRIPT_SANDBOXING must be NO on this target."
    exit 1
  fi
}

set_key CFBundleVersion "$BUILD_NUMBER"

# Restated rather than left to the generator, so a target whose
# MARKETING_VERSION drifted still ships the same short version as the app.
if [[ -n "${MARKETING_VERSION:-}" ]]; then
  set_key CFBundleShortVersionString "$MARKETING_VERSION"
fi

echo "note: ${FULL_PRODUCT_NAME:-product} stamped ${MARKETING_VERSION:-?} ($BUILD_NUMBER)"
