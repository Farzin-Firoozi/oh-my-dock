#!/usr/bin/env bash
set -euo pipefail

# Pinned release tag and commit SHA for supply-chain integrity
DOCKUTIL_VERSION="3.1.3"
DOCKUTIL_COMMIT="640c520ce142a5f21e56fda88a95b4e4d6576042"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

FORCE=false
for arg in "$@"; do
  case "${arg}" in
    --force)
      FORCE=true
      ;;
    -h|--help)
      echo "Usage: $0 [--force]"
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Usage: $0 [--force]" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET_DIR="${REPO_ROOT}/App/Resources/Helpers"
TARGET_BIN="${TARGET_DIR}/dockutil"
VERSION_FILE="${TARGET_DIR}/dockutil.version"
THIRD_PARTY_DIR="${REPO_ROOT}/ThirdParty/dockutil"

EXPECTED_VERSION_CONTENT="${DOCKUTIL_VERSION} ${DOCKUTIL_COMMIT}"

# Short-circuit if binary and version match, unless --force was requested
if [[ "${FORCE}" == false && -f "${TARGET_BIN}" && -f "${VERSION_FILE}" ]]; then
  CURRENT_VERSION_CONTENT="$(cat "${VERSION_FILE}" 2>/dev/null || true)"
  if [[ "${CURRENT_VERSION_CONTENT}" == "${EXPECTED_VERSION_CONTENT}" ]]; then
    echo "dockutil is already built and up to date at ${TARGET_BIN} (${EXPECTED_VERSION_CONTENT})."
    echo "Use --force to rebuild."
    exit 0
  fi
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "==> Cloning dockutil (${DOCKUTIL_VERSION}) into temporary directory..."
git clone --depth 1 --branch "${DOCKUTIL_VERSION}" https://github.com/kcrawford/dockutil.git "${TMP_DIR}"

echo "==> Verifying commit integrity..."
CHECKED_OUT_COMMIT="$(git -C "${TMP_DIR}" rev-parse HEAD)"
if [[ "${CHECKED_OUT_COMMIT}" != "${DOCKUTIL_COMMIT}" ]]; then
  echo "Error: Checked out commit (${CHECKED_OUT_COMMIT}) does not match pinned commit (${DOCKUTIL_COMMIT})" >&2
  exit 1
fi

echo "==> Updating third-party license notices..."
mkdir -p "${THIRD_PARTY_DIR}"
if [[ -f "${TMP_DIR}/LICENSE" ]]; then
  cp "${TMP_DIR}/LICENSE" "${THIRD_PARTY_DIR}/LICENSE"
fi
if [[ -f "${TMP_DIR}/NOTICE" ]]; then
  cp "${TMP_DIR}/NOTICE" "${THIRD_PARTY_DIR}/NOTICE"
fi

echo "==> Building dockutil release binary..."
cd "${TMP_DIR}"

BUILT_BIN=""
if [[ -f "Package.swift" ]]; then
  echo "Detected SwiftPM package. Attempting universal binary build (arm64 + x86_64)..."
  if ! swift build -c release --arch arm64 --arch x86_64; then
    echo "Warning: Universal build failed. Falling back to host architecture build..." >&2
    swift build -c release
  fi

  BIN_DIR="$(swift build -c release --show-bin-path 2>/dev/null || true)"
  if [[ -n "${BIN_DIR}" && -f "${BIN_DIR}/dockutil" ]]; then
    BUILT_BIN="${BIN_DIR}/dockutil"
  else
    BUILT_BIN="$(find "${TMP_DIR}/.build" -type f -name dockutil ! -path '*/Objects*' ! -path '*.dSYM*' | head -n 1)"
  fi
elif compgen -G "./*.xcodeproj" >/dev/null || compgen -G "./*.xcworkspace" >/dev/null; then
  echo "Detected Xcode project. Attempting universal binary build (arm64 + x86_64)..."
  if ! xcodebuild -configuration Release ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" build; then
    echo "Warning: Universal xcodebuild failed. Falling back to host architecture build..." >&2
    xcodebuild -configuration Release build
  fi
  BUILT_BIN="$(find "${TMP_DIR}/build" -type f -name dockutil ! -path '*.dSYM*' | head -n 1)"
else
  echo "Error: Unrecognized build system in dockutil repository" >&2
  exit 1
fi

if [[ -z "${BUILT_BIN}" || ! -f "${BUILT_BIN}" ]]; then
  echo "Error: Could not locate built dockutil binary" >&2
  exit 1
fi

echo "==> Installing binary to ${TARGET_BIN}..."
mkdir -p "${TARGET_DIR}"
cp "${BUILT_BIN}" "${TARGET_BIN}"
chmod +x "${TARGET_BIN}"

echo "${EXPECTED_VERSION_CONTENT}" > "${VERSION_FILE}"

echo "==> Signing binary with identity '${CODESIGN_IDENTITY}'..."
codesign --force --sign "${CODESIGN_IDENTITY}" --options runtime "${TARGET_BIN}"

echo "==> dockutil build completed successfully."
echo "==> Binary architecture info:"
lipo -info "${TARGET_BIN}"

echo "==> Code signature info:"
codesign -dv "${TARGET_BIN}" 2>&1
