#!/usr/bin/env bash
# Free release path: ad-hoc signed (no Developer ID), NOT notarized.
# Produces dist/OhMyDock-<version>.zip and .zip.sha256.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

for tool in xcodegen xcodebuild codesign ditto shasum make; do
  command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done

# Version: MARKETING_VERSION if set, else CFBundleShortVersionString from project.yml.
VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/p' project.yml | head -n1)"
if [[ -z "${VERSION}" ]]; then
  VERSION="$(sed -nE 's/^[[:space:]]*CFBundleShortVersionString:[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/p' project.yml | head -n1)"
fi
[[ -n "${VERSION}" ]] || die "could not read version (MARKETING_VERSION / CFBundleShortVersionString) from project.yml"
[[ "${VERSION}" =~ ^[0-9A-Za-z._-]+$ ]] || die "unexpected version string: ${VERSION}"

HELPER_SRC="App/Resources/Helpers/dockutil"
if [[ ! -x "${HELPER_SRC}" ]]; then
  step "dockutil helper missing, building it"
  make dockutil
  [[ -x "${HELPER_SRC}" ]] || die "make dockutil did not produce ${HELPER_SRC}"
fi

step "Generating Xcode project"
make generate

step "Building Release"
rm -rf build/Build/Products/Release
xcodebuild -project OhMyDock.xcodeproj -scheme OhMyDock -configuration Release \
  -derivedDataPath build build

APP="${ROOT}/build/Build/Products/Release/OhMyDock.app"
[[ -d "${APP}" ]] || die "built app not found at ${APP}"
HELPER="${APP}/Contents/Helpers/dockutil"
[[ -f "${HELPER}" ]] || die "dockutil helper not embedded at ${HELPER}"
CLI="${APP}/Contents/Helpers/ohmydock"
[[ -f "${CLI}" ]] || die "ohmydock CLI not embedded at ${CLI}"

# Inside-out: nested code first, then the bundle. --force re-signs anything Xcode signed.
SIGN=(codesign --force --sign - --options runtime --timestamp=none)

step "Ad-hoc signing dockutil helper"
"${SIGN[@]}" "${HELPER}"

step "Ad-hoc signing ohmydock CLI"
"${SIGN[@]}" "${CLI}"

# Any other nested code (frameworks, XPC, dylibs) before the app itself.
while IFS= read -r nested; do
  step "Ad-hoc signing ${nested#"${APP}/"}"
  "${SIGN[@]}" "${nested}"
done < <(find "${APP}/Contents" \( -name '*.framework' -o -name '*.xpc' -o -name '*.dylib' -o -name '*.appex' \) -prune -print 2>/dev/null | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

step "Ad-hoc signing app"
"${SIGN[@]}" "${APP}"

step "Verifying signatures"
codesign --verify --deep --strict --verbose=2 "${HELPER}"
codesign --verify --deep --strict --verbose=2 "${CLI}"
codesign --verify --deep --strict --verbose=2 "${APP}"

DIST="${ROOT}/dist"
ZIP="${DIST}/OhMyDock-${VERSION}.zip"
SHA="${ZIP}.sha256"
mkdir -p "${DIST}"
rm -f "${ZIP}" "${SHA}"

step "Creating ${ZIP#"${ROOT}/"}"
ditto -c -k --keepParent --norsrc --noextattr --noqtn "${APP}" "${ZIP}"
[[ -s "${ZIP}" ]] || die "zip creation failed"

(cd "${DIST}" && shasum -a 256 "OhMyDock-${VERSION}.zip" > "OhMyDock-${VERSION}.zip.sha256")

echo
echo "Release ${VERSION} (ad-hoc signed, not notarized)"
echo "  zip:    ${ZIP}"
echo "  sha256: ${SHA}"
echo "  hash:   $(cut -d' ' -f1 "${SHA}")"
