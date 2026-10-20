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

helper_sealed_in_app() {
  local rel_path="$1"
  local helper_path="${APP_PATH}/Contents/${rel_path}"
  local code_resources="${APP_PATH}/Contents/_CodeSignature/CodeResources"
  local errs=()

  if [[ ! -f "${helper_path}" ]]; then
    echo "Helper binary missing at '${helper_path}'"
    return 1
  fi

  local own_status=0
  local own_out=""
  own_out="$(codesign --verify --strict "${helper_path}" 2>&1)" || own_status=$?
  if [[ ${own_status} -ne 0 ]]; then
    errs+=("${rel_path} does not have a valid independent signature: ${own_out}")
  fi

  local helper_dv=""
  helper_dv="$(codesign -dv "${helper_path}" 2>&1 || true)"
  if [[ "${helper_dv}" != *"CodeDirectory"* ]]; then
    errs+=("${rel_path} is missing independent CodeDirectory")
  fi

  if [[ ! -f "${code_resources}" ]]; then
    errs+=("App CodeResources missing at '${code_resources}'")
  else
    if ! grep -q "${rel_path}" "${code_resources}"; then
      errs+=("CodeResources does not seal ${rel_path}")
    else
      local helper_v4=""
      helper_v4="$(codesign -d --verbose=4 "${helper_path}" 2>&1 || true)"
      local helper_cdhash=""
      while IFS= read -r line; do
        if [[ "${line}" =~ ^CDHash=(.*) ]]; then
          helper_cdhash="${BASH_REMATCH[1]}"
          break
        fi
      done <<< "${helper_v4}"

      if [[ -z "${helper_cdhash}" ]]; then
        errs+=("Could not extract ${rel_path} CDHash")
      elif ! grep -qi "${helper_cdhash}" "${code_resources}"; then
        errs+=("${rel_path} CDHash (${helper_cdhash}) does not match app CodeResources seal")
      fi
    fi
  fi

  if [[ ${#errs[@]} -gt 0 ]]; then
    printf '%s\n' "${errs[@]}"
    return 1
  fi
  return 0
}

count_url_scheme() {
  python3 - <<'PY' "${INFO_PLIST}"
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as handle:
    plist = plistlib.load(handle)
count = 0
for entry in plist.get("CFBundleURLTypes", []):
    for scheme in entry.get("CFBundleURLSchemes", []):
        if scheme == "ohmydock":
            count += 1
print(count)
PY
}

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
DOCKUTIL_PATH="${APP_PATH}/Contents/Helpers/dockutil"
CLI_PATH="${APP_PATH}/Contents/Helpers/ohmydock"

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

# Check 2: Third-party licenses (dockutil, KeyboardShortcuts, swift-argument-parser)
CHECK2_DESC="Third-party licenses exist under Contents/Resources/ThirdParty"
DOCKUTIL_LICENSE="${APP_PATH}/Contents/Resources/ThirdParty/dockutil/LICENSE"
KEYBOARDSHORTCUTS_LICENSE="${APP_PATH}/Contents/Resources/ThirdParty/KeyboardShortcuts/LICENSE"
ARGPARSE_LICENSE="${APP_PATH}/Contents/Resources/ThirdParty/swift-argument-parser/LICENSE"
NOTICES_SRC="${APP_PATH}/Contents/Resources/THIRD_PARTY_NOTICES.md"

MISSING_LICENSES=()
if [[ ! -f "${DOCKUTIL_LICENSE}" || ! -s "${DOCKUTIL_LICENSE}" ]]; then
  MISSING_LICENSES+=("Contents/Resources/ThirdParty/dockutil/LICENSE")
fi
if [[ ! -f "${KEYBOARDSHORTCUTS_LICENSE}" || ! -s "${KEYBOARDSHORTCUTS_LICENSE}" ]]; then
  MISSING_LICENSES+=("Contents/Resources/ThirdParty/KeyboardShortcuts/LICENSE")
fi
if [[ ! -f "${ARGPARSE_LICENSE}" || ! -s "${ARGPARSE_LICENSE}" ]]; then
  MISSING_LICENSES+=("Contents/Resources/ThirdParty/swift-argument-parser/LICENSE")
fi

CHECK2_ERRS=()
if [[ ${#MISSING_LICENSES[@]} -gt 0 ]]; then
  CHECK2_ERRS+=("Missing or empty license file(s): ${MISSING_LICENSES[*]}")
fi
if [[ ! -f "${NOTICES_SRC}" ]] || ! grep -q 'swift-argument-parser' "${NOTICES_SRC}" 2>/dev/null; then
  CHECK2_ERRS+=("THIRD_PARTY_NOTICES.md missing or does not mention swift-argument-parser")
fi

if [[ ${#CHECK2_ERRS[@]} -eq 0 ]]; then
  pass 2 "${CHECK2_DESC}"
else
  fail 2 "${CHECK2_DESC}" "${CHECK2_ERRS[*]}"
fi

# Check 3: Bundled helpers exist, are executable, and ohmydock version --json works
CHECK3_DESC="Helpers ohmydock and dockutil exist; ohmydock version --json reports schemaVersion"
CHECK3_ERRS=()

if [[ ! -f "${DOCKUTIL_PATH}" ]]; then
  CHECK3_ERRS+=("dockutil not found at '${DOCKUTIL_PATH}'")
elif [[ ! -x "${DOCKUTIL_PATH}" ]]; then
  CHECK3_ERRS+=("dockutil at '${DOCKUTIL_PATH}' is not executable")
fi

if [[ ! -f "${CLI_PATH}" ]]; then
  CHECK3_ERRS+=("ohmydock not found at '${CLI_PATH}'")
elif [[ ! -x "${CLI_PATH}" ]]; then
  CHECK3_ERRS+=("ohmydock at '${CLI_PATH}' is not executable")
else
  VERSION_JSON=""
  VERSION_STATUS=0
  VERSION_JSON="$("${CLI_PATH}" version --json 2>/dev/null)" || VERSION_STATUS=$?
  if [[ ${VERSION_STATUS} -ne 0 ]]; then
    CHECK3_ERRS+=("ohmydock version --json failed (exit ${VERSION_STATUS})")
  elif ! printf '%s' "${VERSION_JSON}" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
assert doc.get("schemaVersion") == 1, doc
assert doc.get("command") == "version", doc
assert doc.get("ok") is True, doc
assert doc.get("result", {}).get("version"), doc
'; then
    CHECK3_ERRS+=("ohmydock version --json output missing schemaVersion 1 or version field")
  else
    BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST}" 2>/dev/null || true)"
    CLI_VERSION="$(printf '%s' "${VERSION_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["version"])')"
    if [[ -z "${BUNDLE_VERSION}" || "${BUNDLE_VERSION}" != "${CLI_VERSION}" ]]; then
      CHECK3_ERRS+=("CLI version '${CLI_VERSION}' does not match CFBundleShortVersionString '${BUNDLE_VERSION}'")
    fi
  fi
fi

if [[ ${#CHECK3_ERRS[@]} -eq 0 ]]; then
  pass 3 "${CHECK3_DESC}"
else
  fail 3 "${CHECK3_DESC}" "${CHECK3_ERRS[*]}"
fi

# Check 4: codesign --verify --deep --strict --verbose=2 passes on app and both helpers
CHECK4_DESC="codesign --verify --deep --strict --verbose=2 passes on app, dockutil, and ohmydock"
CHECK4_ERRS=()

for target in "${APP_PATH}" "${DOCKUTIL_PATH}" "${CLI_PATH}"; do
  label="${target#"${APP_PATH}/"}"
  [[ "${label}" == "${APP_PATH}" ]] && label="app bundle"
  if [[ ! -e "${target}" ]]; then
    CHECK4_ERRS+=("${label} missing; cannot verify codesign")
    continue
  fi
  verify_out=""
  verify_status=0
  verify_out="$(codesign --verify --deep --strict --verbose=2 "${target}" 2>&1)" || verify_status=$?
  if [[ ${verify_status} -ne 0 ]]; then
    CHECK4_ERRS+=("${label} verification failed (exit ${verify_status}): ${verify_out}")
  fi
done

if [[ ${#CHECK4_ERRS[@]} -eq 0 ]]; then
  pass 4 "${CHECK4_DESC}"
else
  fail 4 "${CHECK4_DESC}" "${CHECK4_ERRS[*]}"
fi

# Check 5: App and helpers are ad-hoc signed (Signature=adhoc)
CHECK5_DESC="App, dockutil, and ohmydock are ad-hoc signed (Signature=adhoc)"
CHECK5_ERRS=()

for target in "${APP_PATH}" "${DOCKUTIL_PATH}" "${CLI_PATH}"; do
  label="${target#"${APP_PATH}/"}"
  [[ "${label}" == "${APP_PATH}" ]] && label="app bundle"
  if [[ ! -e "${target}" ]]; then
    CHECK5_ERRS+=("${label} missing; cannot verify ad-hoc signature")
    continue
  fi
  sign_info="$(codesign -dv "${target}" 2>&1 || true)"
  if [[ "${sign_info}" != *"Signature=adhoc"* ]]; then
    CHECK5_ERRS+=("${label} is not ad-hoc signed (Signature=adhoc not found in codesign -dv)")
  fi
done

if [[ ${#CHECK5_ERRS[@]} -eq 0 ]]; then
  pass 5 "${CHECK5_DESC}"
else
  fail 5 "${CHECK5_DESC}" "${CHECK5_ERRS[*]}"
fi

# Check 6: Helpers have independent signatures sealed into the app
CHECK6_DESC="Bundled helpers have valid signatures sealed into the app CodeResources"
CHECK6_ERRS=()

while IFS= read -r line; do
  [[ -n "${line}" ]] && CHECK6_ERRS+=("${line}")
done < <(
  helper_sealed_in_app "Helpers/dockutil" || true
  helper_sealed_in_app "Helpers/ohmydock" || true
)

if [[ ${#CHECK6_ERRS[@]} -eq 0 ]]; then
  pass 6 "${CHECK6_DESC}"
else
  fail 6 "${CHECK6_DESC}" "${CHECK6_ERRS[*]}"
fi

# Check 7: Info.plist LSMinimumSystemVersion, LSUIElement, and ohmydock URL scheme
CHECK7_DESC="Info.plist LSMinimumSystemVersion=14.0, LSUIElement=true, and ohmydock URL scheme once"
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

  SCHEME_COUNT="$(count_url_scheme)"
  if [[ "${SCHEME_COUNT}" -ne 1 ]]; then
    CHECK7_ERRS+=("Expected CFBundleURLTypes to register scheme 'ohmydock' exactly once, found ${SCHEME_COUNT}")
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
