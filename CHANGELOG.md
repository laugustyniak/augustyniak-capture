# Changelog

## 0.2.0 — 2026-09-07

- Show the installed application version and build number in the desktop footer.
- Include the Git revision in desktop builds made with `tool/deploy.sh`;
  modified checkouts are marked `dirty`.
- Open the latest GitHub release and its changes from the footer on request.
  No automatic update checks or background network requests are introduced.

This is the first tagged release. Earlier development used `0.1.0+1` without
release tags; this entry describes the versioning changes, not that entire history.

## Release procedure

1. Update `version` in `pubspec.yaml` and add the changes here. Increment the
   build number as well as the version; Flutter embeds both in the application.
2. Run `flutter analyze`, `flutter test`, and build the target desktop platform.
3. Merge the reviewed branch with a merge commit, then create an annotated
   `v<version>` tag on that merge commit and publish a GitHub Release.
4. Build/install from that tag using `tool/deploy.sh --run`. Verify the footer
   against the release and check the installed executable, not just the build.

Direct `flutter build` commands still embed the version and build number. To
include a source revision, pass `--dart-define=APP_GIT_SHA=<revision>`.
The footer's release link opens GitHub for manual comparison; it does not claim
that the installed version is current without checking.
