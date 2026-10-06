#!/usr/bin/env bash
# Build and reinstall on every target reachable from this machine.
#
# Three targets, run in turn, each reported as OK, SKIP or FAIL. A target
# that cannot run here (no phone attached, Mac asleep) is a SKIP and the
# others still run; the exit code is non-zero only when one of them FAILED.
#
#   1. this host        `tool/deploy.sh` — Linux or macOS, decided by uname
#   2. android          `tool/deploy.sh --android` — every adb device
#   3. macos (remote)   from Linux only: ssh to the Mac, build the same commit
#                       there in its own worktree, run `tool/deploy.sh`
#
# The remote build uses a commit, not a working tree: it checks out `HEAD` of
# this checkout, which therefore has to exist on `origin`. A dirty or unpushed
# tree is refused for that target rather than shipped as something else.
# The Mac's worktree is `.worktrees/deploy` in its clone, so the clone's own
# checkout is never moved, and `tool/deploy.sh` restores the signing config
# there exactly as it does for any fresh worktree.
#
# Each host reads its own defines file (`~/.config/<app>/deploy.defines.json`),
# so no credential crosses ssh.
#
#   tool/deploy-all.sh                          # every target
#   tool/deploy-all.sh --only android,host      # a subset: host, android, macos
#
# Environment:
#   DEPLOY_MAC_HOST   ssh host of the Mac            (default: macbook-pro)
#   DEPLOY_MAC_REPO   path of the clone on the Mac   (default: ~/github/tools/augustyniak-capture)
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

only="host,android,macos"
while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      [ $# -ge 2 ] || { echo "deploy-all: --only needs a list" >&2; exit 2; }
      only="$2"
      shift 2
      ;;
    -h|--help)
      awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' \
        "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) echo "deploy-all: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

mac_host="${DEPLOY_MAC_HOST:-macbook-pro}"
mac_repo="${DEPLOY_MAC_REPO:-~/github/tools/augustyniak-capture}"

wanted() { case ",$only," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

summary=()
failed=0

record() {
  # $1 = target, $2 = OK|SKIP|FAIL, $3 = detail
  summary+=("$(printf '%-8s %-5s %s' "$1" "$2" "$3")")
  [ "$2" = FAIL ] && failed=1
  return 0
}

if wanted host; then
  echo "=== host ($(uname -s))"
  if tool/deploy.sh; then
    record host OK "$(uname -s) install"
  else
    record host FAIL "tool/deploy.sh exited $?"
  fi
fi

if wanted android; then
  echo "=== android"
  tool/deploy.sh --android
  status=$?
  case "$status" in
    0) record android OK "every attached device" ;;
    3) record android SKIP "no adb, or no device that answers" ;;
    # No uninstall hint here: an exit code cannot say why. `deploy.sh` prints
    # the backup-then-uninstall advice itself, per device, and only for a
    # signature mismatch (#243).
    *) record android FAIL "tool/deploy.sh --android exited $status — see output above" ;;
  esac
fi

if wanted macos; then
  echo "=== macos (remote: $mac_host)"
  revision="$(git rev-parse HEAD)"
  if [ "$(uname -s)" = Darwin ]; then
    record macos SKIP "this host is the Mac — covered by 'host'"
  elif [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    record macos SKIP "working tree has uncommitted changes; the Mac builds commits"
  elif [ -z "$(git branch -r --contains "$revision" 2>/dev/null)" ]; then
    record macos SKIP "HEAD ${revision:0:12} is not on origin — push it first"
  elif ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$mac_host" true 2>/dev/null; then
    record macos SKIP "$mac_host not reachable over ssh"
  else
    # The script travels on stdin into a login zsh — the macOS default, and
    # the one whose profile puts `flutter` on PATH — so nothing is quoted
    # twice. `$mac_repo` is left unquoted there so a leading `~` expands.
    if ssh -o BatchMode=yes "$mac_host" zsh -l -s <<REMOTE
set -e
cd $mac_repo
git fetch -q origin
if [ -d .worktrees/deploy ]; then
  git -C .worktrees/deploy checkout -q --detach $revision
else
  git worktree add -q --detach .worktrees/deploy $revision
fi
cd .worktrees/deploy
tool/deploy.sh
REMOTE
    then
      record macos OK "$mac_host at ${revision:0:12}"
    else
      record macos FAIL "remote build or install on $mac_host failed"
    fi
  fi
fi

echo
echo "=== deploy summary"
printf '%s\n' "${summary[@]}"
exit "$failed"
