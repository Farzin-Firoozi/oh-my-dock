#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERIFY_SCRIPT="${REPO_ROOT}/scripts/verify-release.sh"

if [[ ! -x "${VERIFY_SCRIPT}" ]]; then
  echo "Error: verify-release.sh script not found or not executable at '${VERIFY_SCRIPT}'" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

FAKE_APP="${TMP_DIR}/OhMyDock.app"
mkdir -p "${FAKE_APP}/Contents/MacOS"
mkdir -p "${FAKE_APP}/Contents/Helpers"
mkdir -p "${FAKE_APP}/Contents/Resources"

cat << 'EOF' > "${FAKE_APP}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>io.github.farzin-firoozi.OhMyDock</string>
	<key>CFBundleExecutable</key>
	<string>OhMyDock</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF

printf "#!/bin/sh\nexit 0\n" > "${FAKE_APP}/Contents/MacOS/OhMyDock"
printf "#!/bin/sh\nexit 0\n" > "${FAKE_APP}/Contents/Helpers/dockutil"
chmod +x "${FAKE_APP}/Contents/MacOS/OhMyDock" "${FAKE_APP}/Contents/Helpers/dockutil"

# Sign helper first, then sign outer app bundle
codesign -s - "${FAKE_APP}/Contents/Helpers/dockutil"
codesign -s - "${FAKE_APP}"

echo "==> Test 1: Asserting verify-release.sh FAILS when licenses are missing..."
TEST1_STATUS=0
TEST1_OUTPUT=""
TEST1_OUTPUT="$("${VERIFY_SCRIPT}" "${FAKE_APP}" 2>&1)" || TEST1_STATUS=$?

printf '%s\n' "${TEST1_OUTPUT}" | sed 's/^/    /'

if [[ ${TEST1_STATUS} -eq 0 ]]; then
  echo "Assertion failed: verify-release.sh was expected to fail on missing licenses, but returned 0." >&2
  exit 1
fi

if ! echo "${TEST1_OUTPUT}" | grep -q '\[FAIL\] Check 2:'; then
  echo "Assertion failed: expected Check 2 (licenses) failure in output, got:" >&2
  exit 1
fi

if ! echo "${TEST1_OUTPUT}" | grep -q 'Release verification FAILED'; then
  echo "Assertion failed: expected summary to state 'Release verification FAILED', got:" >&2
  exit 1
fi

echo "[PASS] verify-release.sh properly failed on missing licenses (exit code ${TEST1_STATUS})."
echo ""

echo "==> Test 2: Adding licenses and asserting verify-release.sh PASSES..."
mkdir -p "${FAKE_APP}/Contents/Resources/ThirdParty/dockutil"
mkdir -p "${FAKE_APP}/Contents/Resources/ThirdParty/KeyboardShortcuts"
echo "Apache License Version 2.0" > "${FAKE_APP}/Contents/Resources/ThirdParty/dockutil/LICENSE"
echo "MIT License" > "${FAKE_APP}/Contents/Resources/ThirdParty/KeyboardShortcuts/LICENSE"

# Re-sign app because Resources were added
codesign -f -s - "${FAKE_APP}"

TEST2_STATUS=0
TEST2_OUTPUT=""
TEST2_OUTPUT="$("${VERIFY_SCRIPT}" "${FAKE_APP}" 2>&1)" || TEST2_STATUS=$?

printf '%s\n' "${TEST2_OUTPUT}" | sed 's/^/    /'

if [[ ${TEST2_STATUS} -ne 0 ]]; then
  echo "Assertion failed: verify-release.sh was expected to pass with valid bundle, but exited with ${TEST2_STATUS}." >&2
  exit 1
fi

if ! echo "${TEST2_OUTPUT}" | grep -q 'Release verification PASSED'; then
  echo "Assertion failed: expected summary to state 'Release verification PASSED', got:" >&2
  exit 1
fi

echo "[PASS] verify-release.sh passed all checks on complete bundle."
echo ""
echo "==> All test-verify-release checks completed successfully."
