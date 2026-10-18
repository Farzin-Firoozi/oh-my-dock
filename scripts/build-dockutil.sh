#!/usr/bin/env bash
set -euo pipefail

# Pinned release tag and commit SHA for supply-chain integrity
DOCKUTIL_VERSION="3.1.3"
DOCKUTIL_COMMIT="640c520ce142a5f21e56fda88a95b4e4d6576042"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

FORCE=false
HOST_ONLY=false
for arg in "$@"; do
  case "${arg}" in
    --force)
      FORCE=true
      ;;
    --host-only)
      HOST_ONLY=true
      ;;
    -h|--help)
      echo "Usage: $0 [--force] [--host-only]"
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Usage: $0 [--force] [--host-only]" >&2
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
EXPECTED_VERSION_CONTENT+=" ${CODESIGN_IDENTITY}"
if [[ "${HOST_ONLY}" == true ]]; then
  EXPECTED_VERSION_CONTENT+=" host-only"
fi

has_runtime_signature() {
  local binary="$1"
  codesign --verify --strict "${binary}" >/dev/null 2>&1 &&
    codesign -d --verbose=4 "${binary}" 2>&1 | grep -E 'flags=.*runtime' >/dev/null
}

# Short-circuit only when the full build configuration and hardened signature match.
if [[ "${FORCE}" == false && -f "${TARGET_BIN}" && -f "${VERSION_FILE}" ]]; then
  CURRENT_VERSION_CONTENT="$(cat "${VERSION_FILE}" 2>/dev/null || true)"
  if [[ "${CURRENT_VERSION_CONTENT}" == "${EXPECTED_VERSION_CONTENT}" ]] &&
    has_runtime_signature "${TARGET_BIN}"; then
    echo "dockutil is already built and up to date at ${TARGET_BIN} (${EXPECTED_VERSION_CONTENT})."
    echo "Use --force to rebuild."
    exit 0
  fi
fi

TMP_DIR="$(mktemp -d)"
INSTALL_TMP=""
STAMP_TMP=""
cleanup() {
  rm -rf "${TMP_DIR}"
  [[ -z "${INSTALL_TMP}" ]] || rm -f "${INSTALL_TMP}"
  [[ -z "${STAMP_TMP}" ]] || rm -f "${STAMP_TMP}"
}
trap cleanup EXIT

# A stamp must never make a failed or differently signed build appear current.
rm -f "${VERSION_FILE}"

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
  if ! swift build --help 2>&1 | grep -Fq -- "--only-use-versions-from-resolved-file"; then
    echo "Error: This Swift toolchain does not support --only-use-versions-from-resolved-file" >&2
    exit 1
  fi
  if [[ ! -f "Package.resolved" ]]; then
    echo "Error: dockutil ${DOCKUTIL_VERSION} does not include Package.resolved; refusing to resolve transitive dependencies unconstrained" >&2
    exit 1
  fi

  if [[ "${HOST_ONLY}" == true ]]; then
    echo "WARNING: Building host-architecture-only dockutil because --host-only was explicitly requested." >&2
    swift build -c release --only-use-versions-from-resolved-file
  else
    echo "Detected SwiftPM package. Building universal binary (arm64 + x86_64)..."
    swift build -c release --arch arm64 --arch x86_64 --only-use-versions-from-resolved-file
  fi

  BUILT_BIN="$(find "${TMP_DIR}/.build" -type f -name dockutil ! -path '*/Objects*' ! -path '*.dSYM*' -print -quit)"
elif compgen -G "./*.xcodeproj" >/dev/null || compgen -G "./*.xcworkspace" >/dev/null; then
  if [[ "${HOST_ONLY}" == true ]]; then
    echo "WARNING: Building host-architecture-only dockutil because --host-only was explicitly requested." >&2
    xcodebuild -configuration Release build
  else
    echo "Detected Xcode project. Building universal binary (arm64 + x86_64)..."
    xcodebuild -configuration Release ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" build
  fi
  BUILT_BIN="$(find "${TMP_DIR}/build" -type f -name dockutil ! -path '*.dSYM*' -print -quit)"
else
  echo "Error: Unrecognized build system in dockutil repository" >&2
  exit 1
fi

if [[ -z "${BUILT_BIN}" || ! -f "${BUILT_BIN}" ]]; then
  echo "Error: Could not locate built dockutil binary" >&2
  exit 1
fi

BUILT_ARCHS="$(lipo -archs "${BUILT_BIN}")"
if [[ "${HOST_ONLY}" == false ]] &&
  { [[ " ${BUILT_ARCHS} " != *" arm64 "* ]] || [[ " ${BUILT_ARCHS} " != *" x86_64 "* ]]; }; then
  echo "Error: Universal build did not produce both arm64 and x86_64 architectures (got: ${BUILT_ARCHS}). Use --host-only only when an explicitly host-only helper is acceptable." >&2
  exit 1
fi

echo "==> Signing and atomically installing binary to ${TARGET_BIN}..."
mkdir -p "${TARGET_DIR}"
INSTALL_TMP="$(mktemp "${TARGET_DIR}/.dockutil.XXXXXX")"
cp "${BUILT_BIN}" "${INSTALL_TMP}"
chmod +x "${INSTALL_TMP}"

echo "==> Signing binary with identity '${CODESIGN_IDENTITY}'..."
CODESIGN_ARGS=(--force --sign "${CODESIGN_IDENTITY}" --options runtime)
if [[ "${CODESIGN_IDENTITY}" != "-" ]]; then
  CODESIGN_ARGS+=(--timestamp)
fi
codesign "${CODESIGN_ARGS[@]}" "${INSTALL_TMP}"

if ! has_runtime_signature "${INSTALL_TMP}"; then
  echo "Error: Signed dockutil failed strict verification or is missing the runtime flag" >&2
  exit 1
fi

mv -f "${INSTALL_TMP}" "${TARGET_BIN}"
INSTALL_TMP=""

STAMP_TMP="$(mktemp "${TARGET_DIR}/.dockutil.version.XXXXXX")"
printf '%s\n' "${EXPECTED_VERSION_CONTENT}" > "${STAMP_TMP}"
mv -f "${STAMP_TMP}" "${VERSION_FILE}"
STAMP_TMP=""

echo "==> dockutil build completed successfully."
echo "==> Binary architecture info:"
lipo -info "${TARGET_BIN}"

echo "==> Code signature info:"
codesign -dv "${TARGET_BIN}" 2>&1
