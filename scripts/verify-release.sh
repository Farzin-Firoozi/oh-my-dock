#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <path-to-OhMyDock.app>" >&2
}

if [[ $# -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  if [[ $# -eq 1 && ("$1" == "-h" || "$1" == "--help") ]]; then
    exit 0
  fi
  exit 1
fi

APP_PATH="$1"
TOTAL_CHECKS=7
FAILURES=0

pass() {
  local check_num="$1"
  local desc="$2"
  printf "[PASS] Check %s: %s\n" "${check_num}" "${desc}"
}

fail() {
  local check_num="$1"
  local desc="$2"
  local reason="${3:-}"
  printf "[FAIL] Check %s: %s\n" "${check_num}" "${desc}"
  if [[ -n "${reason}" ]]; then
    printf "       -> Reason: %s\n" "${reason}"
  fi
  FAILURES=$((FAILURES + 1))
}

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
HELPER_PATH="${APP_PATH}/Contents/Helpers/dockutil"

# Check 1: The .app exists and has Contents/Info.plist with CFBundleIdentifier io.github.farzin-firoozi.OhMyDock
CHECK1_DESC=".app exists and has Contents/Info.plist with CFBundleIdentifier 'io.github.farzin-firoozi.OhMyDock'"
EXPECTED_BUNDLE_ID="io.github.farzin-firoozi.OhMyDock"

if [[ ! -d "${APP_PATH}" ]]; then
  fail 1 "${CHECK1_DESC}" "App path '${APP_PATH}' does not exist or is not a directory"
elif [[ ! -f "${INFO_PLIST}" ]]; then
  fail 1 "${CHECK1_DESC}" "Missing '${INFO_PLIST}'"
else
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${INFO_PLIST}" 2>/dev/null || true)"
  if [[ "${BUNDLE_ID}" == "${EXPECTED_BUNDLE_ID}" ]]; then
    pass 1 "${CHECK1_DESC}"
  else
    fail 1 "${CHECK1_DESC}" "Expected CFBundleIdentifier '${EXPECTED_BUNDLE_ID}', got '${BUNDLE_ID}'"
  fi
fi

# Check 2: dockutil's license text (Apache-2.0 LICENSE) and KeyboardShortcuts license exist under Contents/Resources
CHECK2_DESC="Third-party licenses (dockutil and KeyboardShortcuts) exist under Contents/Resources"
DOCKUTIL_LICENSE="${APP_PATH}/Contents/Resources/ThirdParty/dockutil/LICENSE"
KEYBOARDSHORTCUTS_LICENSE="${APP_PATH}/Contents/Resources/ThirdParty/KeyboardShortcuts/LICENSE"

MISSING_LICENSES=()
if [[ ! -f "${DOCKUTIL_LICENSE}" || ! -s "${DOCKUTIL_LICENSE}" ]]; then
  MISSING_LICENSES+=("Contents/Resources/ThirdParty/dockutil/LICENSE")
fi
if [[ ! -f "${KEYBOARDSHORTCUTS_LICENSE}" || ! -s "${KEYBOARDSHORTCUTS_LICENSE}" ]]; then
  MISSING_LICENSES+=("Contents/Resources/ThirdParty/KeyboardShortcuts/LICENSE")
fi

if [[ ${#MISSING_LICENSES[@]} -eq 0 ]]; then
  pass 2 "${CHECK2_DESC}"
else
  fail 2 "${CHECK2_DESC}" "Missing or empty license file(s): ${MISSING_LICENSES[*]}"
fi

# Check 3: The bundled dockutil helper exists and is executable at Contents/Helpers/dockutil
CHECK3_DESC="Bundled dockutil helper exists and is executable at Contents/Helpers/dockutil"

if [[ ! -f "${HELPER_PATH}" ]]; then
  fail 3 "${CHECK3_DESC}" "dockutil helper binary not found at '${HELPER_PATH}'"
elif [[ ! -x "${HELPER_PATH}" ]]; then
  fail 3 "${CHECK3_DESC}" "dockutil helper at '${HELPER_PATH}' is not executable"
else
  pass 3 "${CHECK3_DESC}"
fi

# Check 4: codesign --verify --deep --strict --verbose=2 passes on the app and on the helper
CHECK4_DESC="codesign --verify --deep --strict --verbose=2 passes on app and helper"
CHECK4_ERRS=()

APP_VERIFY_OUT=""
APP_VERIFY_STATUS=0
APP_VERIFY_OUT="$(codesign --verify --deep --strict --verbose=2 "${APP_PATH}" 2>&1)" || APP_VERIFY_STATUS=$?
if [[ ${APP_VERIFY_STATUS} -ne 0 ]]; then
  CHECK4_ERRS+=("App verification failed (exit code ${APP_VERIFY_STATUS}): ${APP_VERIFY_OUT}")
fi

if [[ -f "${HELPER_PATH}" ]]; then
  HELPER_VERIFY_OUT=""
  HELPER_VERIFY_STATUS=0
  HELPER_VERIFY_OUT="$(codesign --verify --deep --strict --verbose=2 "${HELPER_PATH}" 2>&1)" || HELPER_VERIFY_STATUS=$?
  if [[ ${HELPER_VERIFY_STATUS} -ne 0 ]]; then
    CHECK4_ERRS+=("Helper verification failed (exit code ${HELPER_VERIFY_STATUS}): ${HELPER_VERIFY_OUT}")
  fi
else
  CHECK4_ERRS+=("Helper binary missing; cannot verify codesign on helper")
fi

if [[ ${#CHECK4_ERRS[@]} -eq 0 ]]; then
  pass 4 "${CHECK4_DESC}"
else
  fail 4 "${CHECK4_DESC}" "${CHECK4_ERRS[*]}"
fi

# Check 5: The app and helper are ad-hoc signed (codesign -dv shows Signature=adhoc)
CHECK5_DESC="App and helper are ad-hoc signed (Signature=adhoc)"
CHECK5_ERRS=()

APP_SIGN_INFO="$(codesign -dv "${APP_PATH}" 2>&1 || true)"
if [[ "${APP_SIGN_INFO}" != *"Signature=adhoc"* ]]; then
  CHECK5_ERRS+=("App is not ad-hoc signed (Signature=adhoc not found in codesign -dv)")
fi

if [[ -f "${HELPER_PATH}" ]]; then
  HELPER_SIGN_INFO="$(codesign -dv "${HELPER_PATH}" 2>&1 || true)"
  if [[ "${HELPER_SIGN_INFO}" != *"Signature=adhoc"* ]]; then
    CHECK5_ERRS+=("Helper is not ad-hoc signed (Signature=adhoc not found in codesign -dv)")
  fi
else
  CHECK5_ERRS+=("Helper binary missing; cannot verify ad-hoc signature")
fi

if [[ ${#CHECK5_ERRS[@]} -eq 0 ]]; then
  pass 5 "${CHECK5_DESC}"
else
  fail 5 "${CHECK5_DESC}" "${CHECK5_ERRS[*]}"
fi

# Check 6: The helper was signed before/independently of the app (helper has its own valid signature)
CHECK6_DESC="Bundled helper has its own valid signature sealed into the app"
CHECK6_ERRS=()
CODE_RESOURCES="${APP_PATH}/Contents/_CodeSignature/CodeResources"

if [[ ! -f "${HELPER_PATH}" ]]; then
  CHECK6_ERRS+=("Helper binary missing at '${HELPER_PATH}'")
else
  HELPER_OWN_STATUS=0
  HELPER_OWN_OUT=""
  HELPER_OWN_OUT="$(codesign --verify --strict "${HELPER_PATH}" 2>&1)" || HELPER_OWN_STATUS=$?
  if [[ ${HELPER_OWN_STATUS} -ne 0 ]]; then
    CHECK6_ERRS+=("Helper does not have a valid independent signature: ${HELPER_OWN_OUT}")
  fi

  HELPER_DV="$(codesign -dv "${HELPER_PATH}" 2>&1 || true)"
  if [[ "${HELPER_DV}" != *"CodeDirectory"* ]]; then
    CHECK6_ERRS+=("Helper is missing independent CodeDirectory")
  fi

  if [[ ! -f "${CODE_RESOURCES}" ]]; then
    CHECK6_ERRS+=("App CodeResources missing at '${CODE_RESOURCES}'")
  else
    if ! grep -q 'Helpers/dockutil' "${CODE_RESOURCES}"; then
      CHECK6_ERRS+=("CodeResources does not seal Helpers/dockutil")
    else
      HELPER_V4="$(codesign -d --verbose=4 "${HELPER_PATH}" 2>&1 || true)"
      HELPER_CDHASH=""
      while IFS= read -r line; do
        if [[ "${line}" =~ ^CDHash=(.*) ]]; then
          HELPER_CDHASH="${BASH_REMATCH[1]}"
          break
        fi
      done <<< "${HELPER_V4}"

      if [[ -z "${HELPER_CDHASH}" ]]; then
        CHECK6_ERRS+=("Could not extract helper CDHash")
      elif ! grep -qi "${HELPER_CDHASH}" "${CODE_RESOURCES}"; then
        CHECK6_ERRS+=("Helper CDHash (${HELPER_CDHASH}) does not match app CodeResources seal")
      fi
    fi
  fi
fi

if [[ ${#CHECK6_ERRS[@]} -eq 0 ]]; then
  pass 6 "${CHECK6_DESC}"
else
  fail 6 "${CHECK6_DESC}" "${CHECK6_ERRS[*]}"
fi

# Check 7: App Info.plist LSMinimumSystemVersion is 14.0 and LSUIElement is true
CHECK7_DESC="App Info.plist specifies LSMinimumSystemVersion=14.0 and LSUIElement=true"
CHECK7_ERRS=()

if [[ ! -f "${INFO_PLIST}" ]]; then
  CHECK7_ERRS+=("Info.plist missing at '${INFO_PLIST}'")
else
  MIN_SYS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "${INFO_PLIST}" 2>/dev/null || true)"
  if [[ "${MIN_SYS}" != "14.0" ]]; then
    CHECK7_ERRS+=("Expected LSMinimumSystemVersion '14.0', got '${MIN_SYS}'")
  fi

  UI_ELEM="$(/usr/libexec/PlistBuddy -c "Print :LSUIElement" "${INFO_PLIST}" 2>/dev/null || true)"
  if [[ "${UI_ELEM}" != "true" ]]; then
    CHECK7_ERRS+=("Expected LSUIElement 'true', got '${UI_ELEM}'")
  fi
fi

if [[ ${#CHECK7_ERRS[@]} -eq 0 ]]; then
  pass 7 "${CHECK7_DESC}"
else
  fail 7 "${CHECK7_DESC}" "${CHECK7_ERRS[*]}"
fi

# Summary
PASSED_CHECKS=$((TOTAL_CHECKS - FAILURES))
echo "------------------------------------------------------------"
echo "Release Verification Summary:"
echo "  Total Checks : ${TOTAL_CHECKS}"
echo "  Passed       : ${PASSED_CHECKS}"
echo "  Failed       : ${FAILURES}"
echo "------------------------------------------------------------"

if [[ ${FAILURES} -eq 0 ]]; then
  echo "Release verification PASSED: all checks satisfied."
  exit 0
else
  echo "Release verification FAILED: ${FAILURES} check(s) failed." >&2
  exit 1
fi
