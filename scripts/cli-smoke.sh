#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LIVE_PLIST="${HOME}/Library/Preferences/com.apple.dock.plist"
if [[ ! -f "$LIVE_PLIST" ]]; then
  echo "error: live Dock plist not found at $LIVE_PLIST" >&2
  exit 1
fi

live_stat_before="$(stat -f '%m %z' "$LIVE_PLIST" 2>/dev/null || stat -c '%Y %s' "$LIVE_PLIST")"
live_hash_before="$(shasum -a 256 "$LIVE_PLIST" | awk '{print $1}')"

make dockutil >/dev/null
make cli >/dev/null

CLI="$ROOT/build/Build/Products/Debug/ohmydock"
if [[ ! -x "$CLI" ]]; then
  echo "error: ohmydock not built at $CLI" >&2
  exit 1
fi

# Dev layout: copy dockutil next to the CLI binary for doctor/save backends.
DOCKUTIL="$ROOT/App/Resources/Helpers/dockutil"
if [[ -x "$DOCKUTIL" ]]; then
  cp -f "$DOCKUTIL" "$(dirname "$CLI")/dockutil"
  chmod +x "$(dirname "$CLI")/dockutil"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SUPPORT="$TMP/support"
PLIST="$TMP/dock.plist"
mkdir -p "$SUPPORT"
plutil -create xml1 "$PLIST"
plutil -insert persistent-apps -xml '<array/>' "$PLIST"
plutil -insert persistent-others -xml '<array/>' "$PLIST"

export OHMYDOCK_SUPPORT_DIR="$SUPPORT"
export OHMYDOCK_DOCK_PLIST="$PLIST"
export OHMYDOCK_LOCK_TIMEOUT=5

json_has_schema() {
  local file="$1"
  python3 - <<PY "$file"
import json, sys
path = sys.argv[1]
with open(path) as f:
    doc = json.load(f)
assert doc.get("schemaVersion") == 1, doc
PY
}

run_json() {
  local label="$1"
  shift
  local out="$TMP/out.json"
  local err="$TMP/err.txt"
  set +e
  "$CLI" --json --non-interactive "$@" >"$out" 2>"$err"
  local code=$?
  set -e
  echo "== $label (exit $code)"
  json_has_schema "$out"
  cat "$out"
  return "$code"
}

run_json list list
run_json version version
run_json save save "Smoke profile"
run_json show show "Smoke profile"
run_json export export "Smoke profile"
run_json apply-dry apply "Smoke profile" --dry-run
run_json status status
run_json current current
run_json doctor doctor

# Dock mutations against temp plist only (restore / undo must not touch live plist).
CALC="/System/Applications/Calculator.app"
if [[ -d "$CALC" ]] && [[ -x "$DOCKUTIL" ]]; then
  "$DOCKUTIL" --add "$CALC" --no-restart "$PLIST" >/dev/null 2>&1 || true
fi
run_json apply-write apply "Smoke profile" --yes
snapshot_id="$(python3 - <<'PY' "$TMP/out.json"
import json, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
sid = doc.get("result", {}).get("snapshotID")
if not sid:
    raise SystemExit("missing snapshotID from apply")
print(sid)
PY
)"
run_json restore restore "$snapshot_id" --yes
run_json undo undo

set +e
"$CLI" --json --non-interactive apply "missing-profile-xyz" --dry-run >"$TMP/missing.json" 2>"$TMP/missing.err"
missing_code=$?
set -e
echo "== apply missing (exit $missing_code)"
json_has_schema "$TMP/missing.json"
if [[ "$missing_code" -ne 3 ]]; then
  echo "error: expected exit 3 for missing profile, got $missing_code" >&2
  exit 1
fi

set +e
"$CLI" --json completions zsh >"$TMP/comp_bad.json" 2>"$TMP/comp_bad.err"
comp_code=$?
set -e
echo "== completions --json rejection (exit $comp_code)"
json_has_schema "$TMP/comp_bad.json"
if [[ "$comp_code" -ne 2 ]]; then
  echo "error: expected exit 2 for completions --json, got $comp_code" >&2
  exit 1
fi

live_stat_after="$(stat -f '%m %z' "$LIVE_PLIST" 2>/dev/null || stat -c '%Y %s' "$LIVE_PLIST")"
live_hash_after="$(shasum -a 256 "$LIVE_PLIST" | awk '{print $1}')"

if [[ "$live_stat_before" != "$live_stat_after" ]]; then
  echo "error: live Dock plist mtime changed ($live_stat_before -> $live_stat_after)" >&2
  exit 1
fi
if [[ "$live_hash_before" != "$live_hash_after" ]]; then
  echo "error: live Dock plist hash changed" >&2
  exit 1
fi

# Completions sanity (non-empty, zsh syntax check).
for shell in zsh bash fish; do
  script="$TMP/comp-$shell"
  "$CLI" completions "$shell" >"$script"
  test -s "$script"
  if [[ "$shell" == "zsh" ]]; then
    zsh -n "$script"
  fi
done

echo "cli-smoke: ok"
