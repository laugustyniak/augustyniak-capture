---
description: Build the app and reinstall it on this host, every attached Android device and the Mac
argument-hint: "[host,android,macos]"
allowed-tools: Bash(tool/deploy-all.sh:*), Bash(tool/deploy.sh:*), Bash(git status:*), Bash(git log:*), Bash(git rev-parse:*)
---

Deploy Augustyniak Capture to every target reachable from this machine with
`tool/deploy-all.sh`. The script does the work. Your job is to run it, watch it
and report what it did.

1. Check what is about to ship: `git log --oneline -1` and `git status --short`.
   The macOS target builds the commit on `origin`, not the working tree, so it
   is skipped when `HEAD` is unpushed or the tree is dirty. Say so up front,
   and offer to push only if this is a branch the user asked to ship.
2. Run `tool/deploy-all.sh` in the background, since a full run takes several
   minutes. Pass `--only $ARGUMENTS` when arguments were given (a comma list
   of `host`, `android`, `macos`). Wait for it to finish; do not poll with a
   fixed sleep.
3. Report the `=== deploy summary` block exactly as printed, one line per
   target with OK / SKIP / FAIL. For each SKIP or FAIL, quote the decisive
   line of output and name the fix.

Rules that are not negotiable:

- **Never uninstall the Android app**, not even to get past
  `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Uninstalling deletes the recordings.
  Tell the user to back up from the Config tab and uninstall by hand if
  replacing the build is really intended.
- **Never kill the running desktop app.** The Linux install replaces the bundle
  under it, so tell the user to restart the app to pick the new build up.
- Never pass a token or key on the command line. Each host reads its own
  `~/.config/augustyniak-capture/deploy.defines.json`.
- A SKIP is not a failure. A Mac that is asleep or a phone that is not
  attached is reported, not retried in a loop.
