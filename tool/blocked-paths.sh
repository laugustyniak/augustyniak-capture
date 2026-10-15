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
# committed template. `key.properties.example` passes on its own, because the
# pattern requires `key.properties` to end the path.
set -euo pipefail

GREP=/usr/bin/grep
[ -x "$GREP" ] || GREP=grep

blocked_re='(^|/)(\.agent-tasks/|inbox\.md$|key\.properties$|[^/]*\.(jks|p12|keystore|pem|mobileprovision)$|googleservice-info\.plist$|google-services\.json$|\.env(\.[^/]*)?$)'

hits=$("$GREP" -iE "$blocked_re" | "$GREP" -ivE '(^|/)\.env\.example$' || true)

if [ -n "$hits" ]; then
  printf '%s\n' "$hits"
  exit 1
fi
