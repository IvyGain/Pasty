#!/usr/bin/env bash
# Pasty dev helper — wraps `swift build / run / test` with the env vars
# required when Xcode is installed but `xcode-select` still points at
# the Command Line Tools, or before `sudo xcodebuild -license accept`.
# Once you accept the license and run
#     sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
# you can call plain `swift build` instead.

set -euo pipefail

XCODE_DEV="/Applications/Xcode.app/Contents/Developer"
TOOLCHAIN="${XCODE_DEV}/Toolchains/XcodeDefault.xctoolchain/usr/bin"
SDK="${XCODE_DEV}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

if [ ! -x "${TOOLCHAIN}/swift" ]; then
  echo "✗ Xcode toolchain not found at ${TOOLCHAIN}" >&2
  echo "  Install Xcode from the App Store first." >&2
  exit 1
fi

export DEVELOPER_DIR="${XCODE_DEV}"
export SDKROOT="${SDK}"

cmd="${1:-build}"
shift || true

case "${cmd}" in
  build|run|test|package)
    exec "${TOOLCHAIN}/swift" "${cmd}" "$@"
    ;;
  demo)
    "${TOOLCHAIN}/swift" build
    "${TOOLCHAIN}/swift" run Pasty &
    pid=$!
    echo "Pasty PID: ${pid}"
    sleep 3
    echo "demo 1 — hello $(date +%H:%M:%S)" | pbcopy
    sleep 1
    echo "demo 2 — https://github.com/IvyGain/Pasty" | pbcopy
    sleep 1
    echo "demo 3 — def hello(): return 'pasty'" | pbcopy
    sleep 1
    echo "--- Recent clips ---"
    sqlite3 "${HOME}/Library/Application Support/Pasty/pasty.sqlite" \
      "SELECT id, kind, substr(preview, 1, 60), sourceAppName FROM clips ORDER BY id DESC LIMIT 10;"
    echo "--- FTS5 search for 'pasty' ---"
    sqlite3 "${HOME}/Library/Application Support/Pasty/pasty.sqlite" \
      "SELECT c.id, substr(c.preview, 1, 60) FROM clips c JOIN clips_fts ON clips_fts.rowid = c.id WHERE clips_fts MATCH 'pasty';"
    kill -9 "${pid}" 2>/dev/null || true
    ;;
  *)
    echo "usage: $0 [build|run|test|package|demo] [args...]" >&2
    exit 2
    ;;
esac
