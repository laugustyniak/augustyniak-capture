# A secret scan in the pre-commit hook

Date: 2026-08-09
Status: approved, ready for implementation planning

## Problem

This repository is public and has already accepted a working credential. A Turso
JWT and an R2 secret access key sat inlined in four source files across five
commits; a later commit removed them from the working tree, but `refs/pull/*`
keeps every blob reachable, so rotation was the only real remedy. The Turso token
has since been confirmed revoked (`role was invalidated after token was issued`);
the R2 key could not be verified from outside, because Cloudflare answers every
failed R2 auth with an identical `401`.

`.githooks/pre-commit` already exists and is the right place: it is the only gate
in a repository with no CI, and it stops content *before the commit exists*,
which is the only point where stopping it is reliable. But it matches **paths**
only — `^(\.agent-tasks/|inbox\.md$)` — so it could not have seen either leak.
The recent `.wrangler/` fix is the same shape: another path added after the fact.
A path list only ever covers the leak that already happened.

## What the measurements decided

Four candidate rules were measured against the whole tracked repository and
against the actual leaking commit (`39a2070`). Two results changed the design.

| Rule | False positives today | Catches the Turso leak | Catches the R2 leak |
| --- | --- | --- | --- |
| JWT (`eyJ….eyJ….…`) | 0 | yes, all four files | no |
| Provider prefixes (`sk-`, `sk-ant-`, `gsk_`, `AKIA…`) | 0 | — | — |
| 64-hex, generated files excluded | 0 | no | yes |
| 64-hex, no exclusions | **102, all in `pubspec.lock`** | no | yes |
| Contextual `name = "value"` | 0, with the `enc:v1:` exclusion below | **no** | partly |

**Correction, made when the discrepancy surfaced in a later review:** the `0`
above was originally measured against a draft of the contextual regex that
opened with a `\b` word boundary before the name. That draft never shipped.
The regex that actually shipped has no such boundary and fires on all five of
this codebase's `enc:v1:…` ciphertext fixtures — `token: 'enc:v1:…'`-shaped
test literals are exactly what `name = "value"` matches. The count is zero
today only because of the `enc:v1:` exclusion in §1 below, which this
document did not mention until this correction. Leaving the stale `0` in
place would have been a smaller edit and a worse document.

**No single rule catches both real leaks.** The contextual rule misses Turso
because the source read `tursoAuthToken ?? 'eyJ…'` — the `??` breaks a
name-equals-value pattern. The JWT rule misses R2 because an R2 secret is bare
hex with no recognisable shape.

**An R2 secret is indistinguishable from a `pubspec.lock` checksum.** Both are
exactly 64 hex characters. The rule that would have caught the real leak fires
102 times on one file, and would fire on *every dependency update*. That is not a
threshold to tune — it is why that rule must be bounded by path rather than by
pattern.

## Design

### 1. Four rules, measured rather than assumed

- **JWT** — `eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}`
- **Provider prefixes** — `sk-ant-…`, `sk-…`, `gsk_…`, `AKIA…`
- **Bare 64-hex** — `(^|[^0-9a-f])[0-9a-f]{64}([^0-9a-f]|$)`, generated files excluded
- **Contextual** — one of `secret`, `token`, `password`, `passwd`, `api_key`,
  `apikey`, `access_key`, `accesskey`, `auth_token`, `authtoken`, `auth_key`,
  `authkey` (case-insensitive, with any prefix or suffix around it, so
  `r2SecretAccessKey` and `TURSO_AUTH_TOKEN` both match), then `:` or `=`, then a
  quoted value of 16 or more non-space characters. A quoted value starting
  `enc:v1:` is excluded: that is this codebase's own on-disk ciphertext prefix
  (`lib/features/settings/domain/token_cipher.dart`), and the encrypted-token
  fixture built from it appears, unexcluded, in five places in the tracked
  tree — without this exclusion the rule would refuse its own test suite.

The contextual rule is the only one that does not bet on a known shape: a
20-character password assigned to `password:` matches nothing else here. It is
kept despite being redundant for both historical leaks, because both historical
leaks are the ones we already know about.

**32-hex is deliberately excluded.** It is the shape of an R2 *access key id*,
which is the public half of the pair — it appears in every R2 endpoint URL. It
also has a false positive in `README.md` today. Blocking it would cost noise to
protect something that is not a secret.

### 2. Only added lines, never whole files

The scan reads `git diff --cached -U0` and inspects lines beginning `+`.

Scanning whole staged files would mean that any file already containing a match
blocks every future edit to it, forever, with no fix short of `--no-verify`
becoming habit. A hook people routinely bypass is worse than no hook: it trains
the bypass.

### 3. Portable ERE, no PCRE

The existing hook uses `grep -E`. Lookarounds would force `grep -P`, which is not
in BSD grep and is therefore absent on a clean macOS — the hook would silently
behave differently depending on whether Homebrew's grep is ahead in `PATH`. The
hex rule's "not part of a longer run" condition is expressed as
`(^|[^0-9a-f])…([^0-9a-f]|$)` instead, which was verified against `/usr/bin/grep`
directly.

### 4. Path exclusions apply to the hex rule only

`*.lock`, `.metadata`, `*Package.resolved`, `*.pbxproj`. All are machine-generated
and full of long hex that is never a credential. The other three rules stay
unrestricted — a JWT in a lock file would be a genuine finding.

### 5. The message names the file and the rule, never the value

`path:line  [rule]`. Printing the matched text would put the secret into terminal
scrollback, shell history and any transcript — which is the disclosure the hook
exists to prevent. The file and line are enough to act on.

The message must also say plainly that a match means *rotate it*, not just
unstage it: if the value reached the working tree it may already have reached a
build, a log or a screen share. The existing hook's tone — what the rule is, why
it exists, exactly how to override — is the model to follow.

### 6. `--no-verify` stays the documented override

Already the hook's contract for its path rules. A false positive must have a
one-line escape, or the hook gets disabled wholesale.

## Testing

There is no test harness for shell hooks in this repository, and adding one for a
single script would be more machinery than the script. Verification is by
execution, and every claim in the table above must be reproduced rather than
trusted:

- **Each of the four rules fires**, proven by staging a file containing a
  matching value and observing the refusal naming that rule.
- **The real leak is caught.** Stage the pre-fix content of
  `lib/features/settings/presentation/qr_sync_sheet.dart` from `39a2070` and
  confirm the hook refuses. This is the regression that matters; if it passes,
  the hook does not solve the problem it was written for.
- **`pubspec.lock` does not trip it.** Stage a realistic lock-file change and
  confirm it commits cleanly. This is the false positive that would get the hook
  disabled within a week.
- **A clean commit still commits**, and the existing path rules still refuse
  `.agent-tasks/`.
- **The output contains no secret.** Grep the refusal text for the injected
  value and confirm it is absent.
- **`/usr/bin/grep` is used explicitly or the patterns are ERE-only**, verified
  by running the hook with BSD grep rather than whatever `PATH` offers.

## Risks and non-goals

- **This scans commits, not history.** Everything already in `refs/pull/*` stays
  reachable; rotation remains the only remedy for what leaked.
- **A wordlist of shapes is not a proof.** A credential in an unrecognised format,
  assigned to an unrecognised name, passes. The same honesty the language guard's
  doc comment carries belongs here.
- Not in scope: adopting gitleaks or trufflehog. They carry hundreds of maintained
  rules, but they are an install step on every clone, and this repository's hooks
  currently shell out to nothing but `flutter`. A hook that silently does nothing
  because a tool is missing is worse than no hook — it looks enabled.
- Not in scope: changing the pre-push hook, or scanning at push time.
