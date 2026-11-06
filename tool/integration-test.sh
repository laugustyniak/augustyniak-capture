#!/usr/bin/env bash
# Runs an integration_test against the Linux desktop build, isolated from the
# session of the person running it (#416).
#
#   tool/integration-test.sh integration_test/text_note_capture_test.dart
#
# The test itself points path_provider at a temp directory and the keyring at
# an in-memory map. This wrapper covers what the Dart side cannot reach:
#
# - HOME and XDG_* point at a throwaway directory, so nothing the GTK shell or
#   a plugin resolves on its own lands in the real home;
# - dbus-run-session gives the app a private session bus, so the
#   single-instance GtkApplication cannot hand off to a running copy of the
#   real app, and libsecret never reaches the real keyring;
# - xvfb-run puts the window on a virtual display, so global hotkeys and the
#   clipboard watcher stay off the real desktop.
#
# The flutter tool keeps its own caches: PUB_CACHE is pinned to the real one
# before HOME moves, so the run does not download every package again.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 integration_test/<file>.dart [flutter test args...]" >&2
  exit 2
fi

for tool in dbus-run-session xvfb-run flutter; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required (see docs/architecture/testing.md)" >&2
    exit 2
  fi
done

export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/capture-e2e-home.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/home" "$sandbox/config" "$sandbox/data" "$sandbox/cache" \
  "$sandbox/state" "$sandbox/runtime"
chmod 700 "$sandbox/runtime"

export HOME="$sandbox/home"
export XDG_CONFIG_HOME="$sandbox/config"
export XDG_DATA_HOME="$sandbox/data"
export XDG_CACHE_HOME="$sandbox/cache"
export XDG_STATE_HOME="$sandbox/state"
export XDG_RUNTIME_DIR="$sandbox/runtime"

exec dbus-run-session -- xvfb-run -a flutter test "$@" -d linux
