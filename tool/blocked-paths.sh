#!/usr/bin/env bash
# The one path rule behind "never commit this file" (#305).
#
# Reads newline-separated repo-relative paths on stdin, prints every blocked one
# to stdout and exits 1 if there was any; exits 0 with nothing printed
# otherwise. `.githooks/pre-commit` pipes the staged paths through it, and the
# CI `guard` job pipes every tracked path through it, so the local hook and the
# server-side fallback cannot drift apart.
#
# Matching is case-insensitive. `.gitignore` is: on macOS, where
# `core.ignorecase` is true, `Inbox.md` is ignored just as `inbox.md` is, while
# a case-sensitive hook let the same name through whenever the ignore rule was
# bypassed. Matching is also at any depth, not anchored at the repo root: a
# capture or a keystore in a subdirectory is the same leak.
#
# What each pattern protects:
#   .agent-tasks/, inbox.md       captured content — the user's own dictated notes
#   key.properties                the release keystore's passwords (the one
#                                 artifact that cannot be regenerated)
#   *.jks *.p12 *.keystore        the release keystore itself, and signing certs
#   *.pem                         private keys
#   *.mobileprovision             iOS provisioning profiles
#   GoogleService-Info.plist,     Firebase client configuration
#   google-services.json
#   .env, .env.*                  environment files that hold live credentials
#
# `.env.example` is the exception: `.gitignore` deliberately allows it as the
# committed template. Every other `.env.*` is blocked, so `.env.sample` and
# `.env.template` are too, by design. `key.properties.example` passes on its
# own, because the pattern requires `key.properties` to end the path. A name
# may carry trailing whitespace (`inbox.md `) and a directory may be called
# `.env`; both are blocked. `foo.env` and `prod.env` are not matched: the rule
# needs `.env` to start a path component, which is intended.
#
# The `.env.example` exemption holds only when no directory above it is blocked:
# `.agent-tasks/.env.example` is still a file inside `.agent-tasks/`.
#
# Each path is judged on its own line by grep's exit status (`-q`), never by
# its output. The earlier pipeline read the output, and GNU grep under a UTF-8
# locale treats a path with invalid bytes as binary: it printed "binary file
# matches" instead of the path, so `caf\xe9/inbox.md` read as clean. `-a` is
# kept so the bytes are always treated as text, belt and braces. If grep itself
# fails (exit 2) this script exits 2, never 0: the hook turns any status above
# 1 into "refusing to commit blind".
#
# Input is split on newlines, so a path that itself contains a newline is cut
# in two and is not defended. That is accepted as out of scope.
set -euo pipefail

GREP=/usr/bin/grep
[ -x "$GREP" ] || GREP=grep

blocked_re='(^|/)(\.agent-tasks/|inbox\.md[[:space:]]*$|key\.properties[[:space:]]*$|[^/]*\.(jks|p12|keystore|pem|mobileprovision)[[:space:]]*$|googleservice-info\.plist[[:space:]]*$|google-services\.json[[:space:]]*$|\.env(\.[^/]*)?(/|[[:space:]]*$))'

exempt_re='(^|/)\.env\.example[[:space:]]*$'
match() { printf '%s\n' "$1" | "$GREP" -qiaE "$2"; }   # 0 match, 1 none, 2 grep error

hits=''
# `|| [ -n "$line" ]` keeps a final line that has no trailing newline.
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  rc=0; match "$line" "$blocked_re" || rc=$?
  [ "$rc" -le 1 ] || exit 2
  [ "$rc" -eq 0 ] || continue
  rc=0; match "$line" "$exempt_re" || rc=$?
  [ "$rc" -le 1 ] || exit 2
  if [ "$rc" -eq 0 ] && [ "$line" != "${line%/*}" ]; then
    # The parent is judged twice: with a trailing slash for the directory
    # patterns (`.agent-tasks/`, `.env/`) and without it for the ones that
    # must end the path (`x.jks`, `inbox.md`) — a directory may carry those
    # names too.
    dir=${line%/*}
    rc=0; match "$dir/" "$blocked_re" || rc=$?
    [ "$rc" -le 1 ] || exit 2
    if [ "$rc" -ne 0 ]; then
      rc=0; match "$dir" "$blocked_re" || rc=$?
      [ "$rc" -le 1 ] || exit 2
      [ "$rc" -eq 0 ] || continue
    fi
  elif [ "$rc" -eq 0 ]; then
    continue
  fi
  hits="${hits}${line}"$'\n'
done

if [ -n "$hits" ]; then
  printf '%s' "$hits"
  exit 1
fi
