#!/usr/bin/env bash
# Install GNOME custom keybindings that run the app's shortcut URLs (#381).
#
# Under a native GNOME Wayland session no application can grab a key
# system-wide: `keybinder`, which `LinuxHotkeyRegistrar` goes through, is
# X11-only, and every registration fails at startup. So the desktop owns the
# key instead, and each binding runs
#
#   xdg-open <application id>://shortcut/<ShortcutAction.name>
#
# which a second process forwards to the running instance (or starts the app
# with, when it is not running). The combinations are `ShortcutDefaults` —
# Ctrl+Alt+A/R/N/V — and `test/gnome_shortcuts_test.dart` fails if they drift.
#
# Idempotent: each action owns one fixed dconf path, so a second run rewrites
# the same four entries rather than adding four more. Every other custom
# keybinding in the list is left exactly where it was.
#
# The application identifier is read from `linux/CMakeLists.txt`, never
# restated here — `test/rebrand_test.dart` holds this script to that rule.
#
#   tool/gnome-shortcuts.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
linux_cmake="$repo_root/linux/CMakeLists.txt"

application_id="$(sed -n 's/^set(APPLICATION_ID "\(.*\)").*$/\1/p' "$linux_cmake" | head -1)"
if [ -z "$application_id" ]; then
  echo "gnome-shortcuts: could not read APPLICATION_ID from $linux_cmake" >&2
  exit 1
fi

if ! command -v gsettings >/dev/null 2>&1; then
  echo "gnome-shortcuts: gsettings not found — is this a GNOME session?" >&2
  exit 1
fi

schema="org.gnome.settings-daemon.plugins.media-keys"
base="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings"
slug="${application_id//./-}"

# action:key — ShortcutDefaults.bindings, all on Ctrl+Alt.
bindings=(
  "showWindow:a"
  "toggleRecording:r"
  "newTextNote:n"
  "toggleClipboardHistory:v"
)

# The current list, one path per line. `@as []` (never set) yields nothing.
existing="$(gsettings get "$schema" custom-keybindings | grep -o "'[^']*'" | tr -d "'" || true)"

paths=()
while IFS= read -r path; do
  [ -n "$path" ] && paths+=("$path")
done <<<"$existing"

for entry in "${bindings[@]}"; do
  action="${entry%%:*}"
  key="${entry##*:}"
  path="$base/$slug-$action/"

  found=0
  for known in ${paths[@]+"${paths[@]}"}; do
    [ "$known" = "$path" ] && found=1
  done
  [ "$found" = 1 ] || paths+=("$path")

  relocatable="$schema.custom-keybinding:$path"
  gsettings set "$relocatable" name "$application_id $action"
  gsettings set "$relocatable" command "xdg-open $application_id://shortcut/$action"
  gsettings set "$relocatable" binding "<Control><Alt>$key"
  echo "gnome-shortcuts: Ctrl+Alt+$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]') -> $action"
done

list="["
for i in "${!paths[@]}"; do
  [ "$i" -gt 0 ] && list+=", "
  list+="'${paths[$i]}'"
done
list+="]"
gsettings set "$schema" custom-keybindings "$list"
