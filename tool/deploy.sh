#!/usr/bin/env bash
# Build and install a desktop copy on whichever host this is run from.
#
# This existed as a hand-run sequence until the rebrand, and reconstructing it
# afterwards is what proved it belongs in the repository. Six separate places
# carry the application identifier on Linux alone — the bundle directory, the
# symlink, seven `hicolor` icon file names, the `.desktop` file name, its
# `Icon=` key and its `StartupWMClass` — and a stale copy of any of them costs
# the dock icon or the single-instance handle *without failing anything*. So
# nothing here is written as a literal: the identifiers are read back out of
# `linux/CMakeLists.txt` and `macos/Runner/Configs/AppInfo.xcconfig`, the same
# files `test/rebrand_test.dart` pins, and that test also refuses a copy of
# them appearing in this script.
#
# `StartupWMClass` is the identifier rather than the binary name because the
# GTK runner calls `g_set_prgname(APPLICATION_ID)`, and `WM_CLASS` follows
# `prgname`. Naming the binary there is the plausible wrong answer: the app
# still launches, and only the dock fails to associate the window with it.
#
# **Credentials never reach the command line.** `--dart-define=TURSO_AUTH_TOKEN=…`
# puts a working JWT in the shell history of every machine it is deployed
# from, which is the same class of exposure as committing one. A defines file
# is passed with `--dart-define-from-file` instead, and it is looked for
# outside the repository first, so the usual copy is somewhere `git add -A`
# cannot reach. Absent, the build simply comes up unpaired — that is the
# normal state, not a degraded one: sync settings live in the app's documents
# directory, *outside* the install, so a copy paired once through the Config
# tab or a QR code stays paired across every redeploy after it. Prefer that
# over a defines file for a machine you deploy to more than once.
#
#   tool/deploy.sh                     # build and install for this host
#   tool/deploy.sh --run               # …and launch it when the install lands
#   tool/deploy.sh --defines path.json # seed sync credentials into the build
#   tool/deploy.sh --skip-build        # reinstall the bundle already built
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

defines_file=""
defines_explicit=0
skip_build=0
run_after=0

while [ $# -gt 0 ]; do
  case "$1" in
    --defines)
      [ $# -ge 2 ] || { echo "deploy: --defines needs a file path" >&2; exit 2; }
      defines_file="$2"
      defines_explicit=1
      shift 2
      ;;
    --skip-build) skip_build=1; shift ;;
    --run) run_after=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' \
        "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) echo "deploy: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# --- identity -----------------------------------------------------------
# Read rather than restated. Every value below has exactly one home, and it is
# a file the build system already reads.

linux_cmake="linux/CMakeLists.txt"
app_info="macos/Runner/Configs/AppInfo.xcconfig"

require_value() {
  # $1 = value, $2 = what it is, $3 = where it should have come from
  if [ -z "$1" ]; then
    echo "deploy: could not read $2 from $3" >&2
    exit 1
  fi
}

binary_name="$(sed -n 's/^set(BINARY_NAME "\(.*\)").*$/\1/p' "$linux_cmake" | head -1)"
application_id="$(sed -n 's/^set(APPLICATION_ID "\(.*\)").*$/\1/p' "$linux_cmake" | head -1)"
require_value "$binary_name" "BINARY_NAME" "$linux_cmake"
require_value "$application_id" "APPLICATION_ID" "$linux_cmake"

# The display name is read from the macOS config on every host, deliberately:
# it is the only file that states it as a value rather than embedding it in a
# call, and one source is what keeps a Linux launcher from drifting from the
# Finder's idea of the same app.
display_name="$(sed -n 's/^PRODUCT_NAME = //p' "$app_info" | head -1)"
require_value "$display_name" "PRODUCT_NAME" "$app_info"

# The hyphenated form is what a user types and what a directory is named;
# the underscored form is the binary. Both are derived from the one value.
cli_name="${binary_name//_/-}"

# --- credentials --------------------------------------------------------
# Outside the repository first. A file that is merely gitignored is still one
# `git add -f`, one ignore rule edited later, or one tool staging on the
# user's behalf away from a public commit.

if [ "$defines_explicit" = 0 ]; then
  for candidate in \
    "${XDG_CONFIG_HOME:-$HOME/.config}/$cli_name/deploy.defines.json" \
    "tool/deploy.defines.json"; do
    if [ -f "$candidate" ]; then
      defines_file="$candidate"
      break
    fi
  done
fi

if [ -n "$defines_file" ]; then
  if [ ! -f "$defines_file" ]; then
    echo "deploy: no such defines file: $defines_file" >&2
    exit 1
  fi
  # A defines file inside the working tree that git would happily stage is
  # worth a warning rather than a refusal — it may be a deliberate choice on a
  # throwaway machine, but it is never the safe default.
  case "$defines_file" in
    /*) defines_abs="$defines_file" ;;
    *) defines_abs="$repo_root/$defines_file" ;;
  esac
  case "$defines_abs" in
    "$repo_root"/*)
      if ! git check-ignore -q "$defines_abs" 2>/dev/null; then
        echo "deploy: WARNING — $defines_file sits in the working tree and git" >&2
        echo "        does not ignore it. Move it to" >&2
        echo "        ${XDG_CONFIG_HOME:-\$HOME/.config}/$cli_name/deploy.defines.json" >&2
      fi
      ;;
  esac
  echo "deploy: seeding sync credentials from $defines_file"
  build_args=(--release "--dart-define-from-file=$defines_file")
else
  echo "deploy: no defines file — the build comes up unpaired"
  echo "        (Config tab or a QR pairing configures it, and that survives redeploys)"
  build_args=(--release)
fi

# --- per-host install ---------------------------------------------------

install_linux() {
  local bundle="build/linux/x64/release/bundle"
  local opt_dir="$HOME/.local/opt/$cli_name"
  local bin_dir="$HOME/.local/bin"
  local apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  local icons_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"

  if [ "$skip_build" = 0 ]; then
    flutter build linux "${build_args[@]}"
  fi
  [ -x "$bundle/$binary_name" ] || {
    echo "deploy: no built bundle at $bundle — drop --skip-build" >&2
    exit 1
  }

  rm -rf "$opt_dir"
  mkdir -p "$opt_dir" "$bin_dir" "$apps_dir"
  cp -a "$bundle"/. "$opt_dir"/
  ln -sfn "$opt_dir/$binary_name" "$bin_dir/$cli_name"

  # The GTK runner asks for the icon by name (`gtk_window_set_icon_name`), so
  # the file name is the contract and the sizes are what the theme looks
  # through. Missing tooling costs the icon and nothing else, so it warns
  # rather than failing a deploy that is otherwise complete.
  local source_icon="assets/icon/app_icon_1024.png"
  local size
  if [ -f "$source_icon" ] && command -v convert >/dev/null 2>&1; then
    for size in 16 32 48 64 128 256 512; do
      mkdir -p "$icons_dir/${size}x${size}/apps"
      convert "$source_icon" -resize "${size}x${size}" \
        "$icons_dir/${size}x${size}/apps/$application_id.png"
    done
  elif [ -f "$source_icon" ] && python3 -c 'import PIL' >/dev/null 2>&1; then
    python3 - "$source_icon" "$icons_dir" "$application_id" <<'PY'
import sys, os
from PIL import Image
source, icons_dir, app_id = sys.argv[1:4]
image = Image.open(source)
for size in (16, 32, 48, 64, 128, 256, 512):
    target = os.path.join(icons_dir, f"{size}x{size}", "apps")
    os.makedirs(target, exist_ok=True)
    image.resize((size, size), Image.LANCZOS).save(
        os.path.join(target, f"{app_id}.png")
    )
PY
  else
    echo "deploy: WARNING — no ImageMagick and no Pillow; icons left as they were" >&2
  fi

  cat > "$apps_dir/$application_id.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$display_name
Comment=$(sed -n 's/^description: //p' pubspec.yaml | head -1)
Exec=$opt_dir/$binary_name
Icon=$application_id
Terminal=false
Categories=AudioVideo;Audio;Recorder;
StartupWMClass=$application_id
EOF

  command -v desktop-file-validate >/dev/null 2>&1 \
    && desktop-file-validate "$apps_dir/$application_id.desktop"
  command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$apps_dir" 2>/dev/null
  command -v gtk-update-icon-cache >/dev/null 2>&1 \
    && gtk-update-icon-cache -f -t "$icons_dir" 2>/dev/null

  echo "deploy: installed $display_name"
  echo "        bundle   $opt_dir"
  echo "        command  $bin_dir/$cli_name"
  echo "        launcher $apps_dir/$application_id.desktop"

  if [ "$run_after" = 1 ]; then
    exec "$bin_dir/$cli_name"
  fi
}

install_macos() {
  local app="build/macos/Build/Products/Release/$display_name.app"
  local signing="macos/Runner/Configs/LocalSigning.xcconfig"
  local stash="${XDG_CONFIG_HOME:-$HOME/.config}/$cli_name/LocalSigning.xcconfig"

  # The signing config is untracked on purpose, which means `git worktree add`
  # does not bring it along and a fresh worktree signs ad-hoc — every rebuild
  # then a different application to macOS, and the keyring entry holding the
  # token master key stops opening. Restoring it from outside the tree is the
  # cheap half of that fix; the expensive half is noticing at all.
  if [ ! -f "$signing" ] && [ -f "$stash" ]; then
    echo "deploy: restoring $signing from $stash"
    cp "$stash" "$signing"
  fi
  if [ ! -f "$signing" ]; then
    echo "deploy: WARNING — no $signing; this build signs ad-hoc, so macOS" >&2
    echo "        treats it as a new app and re-prompts for the microphone" >&2
  fi

  if [ "$skip_build" = 0 ]; then
    flutter build macos "${build_args[@]}"
  fi
  [ -d "$app" ] || {
    echo "deploy: no built bundle at $app — drop --skip-build" >&2
    exit 1
  }

  # Replaced rather than merged: copying over a previous install leaves
  # whatever the last build shipped and this one dropped.
  rm -rf "/Applications/$display_name.app"
  cp -R "$app" /Applications/

  echo "deploy: installed $display_name"
  echo "        bundle   /Applications/$display_name.app"
  # The designated requirement is the one fact worth reporting: a `cdhash`
  # form means this build is a stranger to yesterday's keychain grants, and a
  # certificate-leaf form means it is not.
  # `|| true` because this is a report, not a gate, and it is the last command
  # in the function: a refusing `codesign` would otherwise fail a deploy that
  # has already landed.
  codesign -d -r- "/Applications/$display_name.app" 2>&1 | sed 's/^/        /' || true

  if [ "$run_after" = 1 ]; then
    open -a "/Applications/$display_name.app"
  fi
}

case "$(uname -s)" in
  Linux) install_linux ;;
  Darwin) install_macos ;;
  *)
    echo "deploy: no desktop install defined for $(uname -s)" >&2
    exit 1
    ;;
esac
