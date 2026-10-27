#!/usr/bin/env bash
# Build and install the read-only MCP server (`bin/capture_mcp.dart`).
#
# Called by `tool/deploy.sh` after a desktop install, which passes the CLI name
# it derived from the platform files — so, like that script, nothing here
# restates the application identity (`test/rebrand_test.dart` checks both).
#
#   tool/deploy-mcp.sh <cli-name> [--skip-build]
#
# `dart compile exe` refuses `sqlite3` (it ships a build hook), so the build is
# a bundle: `bin/capture_mcp` plus `lib/libsqlite3.*`. The two must stay
# together, so the bundle is installed as a whole directory, never file by
# file. It goes to `~/.local/opt/<cli-name>-mcp/` — deliberately not inside
# the app's own `~/.local/opt/<cli-name>`, which `deploy.sh` wipes on every
# install — and the same place on macOS, outside the signed `.app`.
#
# The bundle is replaced as a whole: copied to `.new`, the old install moved to
# `.old`, `.new` moved into place, `.old` removed. A failure before the swap
# leaves the previous install; the swap itself is two `mv` calls with a short
# window between them, not an atomic operation. If a run dies in that window,
# only `.old` holds a working install, and the next run moves it back first.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  echo "deploy-mcp: $1" >&2
  exit 1
}

[ $# -ge 1 ] || { echo "deploy-mcp: usage: deploy-mcp.sh <cli-name> [--skip-build]" >&2; exit 2; }
cli_name="$1"
shift
skip_build=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build) skip_build=1; shift ;;
    *) echo "deploy-mcp: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
# The name becomes part of paths that are removed and replaced below.
case "$cli_name" in
  ""|*/*|*..*) fail "invalid cli name '$cli_name'" ;;
esac

dest="$HOME/.local/opt/${cli_name}-mcp"
bin_dir="$HOME/.local/bin"
link="$bin_dir/${cli_name}-mcp"
server_name="$cli_name"

# A run that died between the two `mv` calls below left only `.old` holding a
# working install: put it back before anything else can remove it.
if [ ! -e "$dest" ] && [ -e "${dest}.old" ]; then
  mv "${dest}.old" "$dest" || fail "could not recover the previous install from ${dest}.old"
fi

out_dir="build/mcp"
bundle="$out_dir/bundle"
case "$(uname -s)" in
  Linux) sqlite_lib="libsqlite3.so" ;;
  Darwin) sqlite_lib="libsqlite3.dylib" ;;
  *) fail "no MCP install defined for $(uname -s)" ;;
esac

if [ "$skip_build" = 0 ]; then
  command -v dart >/dev/null 2>&1 || fail "dart not found on PATH — install the Dart SDK or use --skip-build"
  dart build cli -t bin/capture_mcp.dart -o "$out_dir" >&2 \
    || fail "dart build cli failed"
fi
[ -d "$bundle" ] || fail "no built MCP bundle at $bundle — drop --skip-build"
[ -x "$bundle/bin/capture_mcp" ] || fail "bundle has no executable bin/capture_mcp"
[ -e "$bundle/lib/$sqlite_lib" ] || fail "bundle has no lib/$sqlite_lib"

# Never replace something the user put where the symlink goes.
if [ -e "$link" ] && [ ! -L "$link" ]; then
  fail "$link exists and is not a symlink — move it away"
fi

mkdir -p "$(dirname "$dest")" "$bin_dir"
rm -rf "${dest}.new"
cp -a "$bundle" "${dest}.new" || { rm -rf "${dest}.new"; fail "could not copy the bundle"; }
if [ -e "$dest" ]; then
  # `dest` is live, so any `.old` is a leftover; a stale directory there would
  # make `mv` move the install into it instead of replacing it.
  rm -rf "${dest}.old"
  mv "$dest" "${dest}.old" || { rm -rf "${dest}.new"; fail "could not move the previous install aside"; }
fi
if ! mv "${dest}.new" "$dest"; then
  [ -e "${dest}.old" ] && mv "${dest}.old" "$dest"
  fail "could not move the new bundle into place"
fi
rm -rf "${dest}.old"
ln -sfn "$dest/bin/capture_mcp" "$link"

echo "deploy: installed MCP server"
echo "        bundle   $dest"
echo "        command  $link"
echo "        register with Claude Code:"
echo "          claude mcp add $server_name -- $link"
echo "        or in ~/.codex/config.toml:"
echo "          [mcp_servers.$server_name]"
echo "          command = \"$link\""
echo "          args = []"
