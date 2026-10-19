#!/usr/bin/env bash
# Static checks for Casks/oh-my-dock.rb — no network, no brew, no system changes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CASK="${ROOT}/Casks/oh-my-dock.rb"

[[ -f "${CASK}" ]] || { echo "missing ${CASK}" >&2; exit 1; }

ruby -c "${CASK}"

required=(
  'cask "oh-my-dock"'
  'version "'
  'sha256 "'
  'url "https://github.com/Farzin-Firoozi/oh-my-dock/releases/download/v'
  'name "oh-my-dock"'
  'desc "'
  'homepage "https://github.com/Farzin-Firoozi/oh-my-dock"'
  'livecheck do'
  'strategy :github_latest'
  'depends_on macos: ">= :sonoma"'
  'app "OhMyDock.app"'
  'postflight do'
  'com.apple.quarantine'
  'zap trash:'
  '~/Library/Application Support/oh-my-dock'
  '~/Library/Preferences/io.github.farzin-firoozi.OhMyDock.plist'
  '~/Library/Caches/io.github.farzin-firoozi.OhMyDock'
  'caveats'
  'not notarized'
)

for needle in "${required[@]}"; do
  grep -Fq "${needle}" "${CASK}" || { echo "missing required fragment: ${needle}" >&2; exit 1; }
done

if grep -Fq 'binary "' "${CASK}"; then
  echo "cask must not declare binary (CLI not shipped yet)" >&2
  exit 1
fi

version_line="$(grep -E '^  version "[0-9]+\.[0-9]+\.[0-9]+"$' "${CASK}" || true)"
[[ -n "${version_line}" ]] || { echo "version line must be semver x.y.z" >&2; exit 1; }

sha_line="$(grep -E '^  sha256 "[0-9a-f]{64}"$' "${CASK}" || true)"
[[ -n "${sha_line}" ]] || { echo "sha256 line must be 64 lowercase hex digits" >&2; exit 1; }

echo "ok: ${CASK}"
