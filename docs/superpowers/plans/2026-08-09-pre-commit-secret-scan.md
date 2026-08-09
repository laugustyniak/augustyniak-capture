# Pre-commit secret scan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `.githooks/pre-commit` refuse a commit whose added lines contain a credential, so the repository's only gate stops matching paths alone.

**Architecture:** One bash block appended to the existing hook. It walks the staged files, extracts only the *added* lines with their line numbers via `git diff --cached -U0` and a small awk, and tests each against four ERE patterns. Findings are reported as `path:line [rule]` — never the matched text.

**Tech Stack:** bash, git, awk, `grep -E`. No new dependency, no new tool to install.

**Spec:** `docs/superpowers/specs/2026-08-09-pre-commit-secret-scan-design.md`

## Global Constraints

- **No new dependencies.** No gitleaks, no trufflehog, nothing to `brew install`. The hook must work on a fresh clone with nothing but git and a POSIX userland.
- **ERE only — never `grep -P`.** BSD grep has no `-P`, so a PCRE pattern would make the hook behave differently depending on whether Homebrew's grep is earlier in `PATH`. The "not part of a longer hex run" condition is written `(^|[^0-9a-f])…([^0-9a-f]|$)`.
- **Scan added lines only**, from `git diff --cached -U0`. Never whole files: a file that already contains a match would otherwise block every future edit to it.
- **The refusal output must never contain the matched value.** Printing it would put the secret in terminal scrollback, shell history and any transcript — the disclosure the hook exists to prevent. Report `path:line [rule]`.
- **The 64-hex rule, and only that rule, skips generated files**: `*.lock`, `.metadata`, `*Package.resolved`, `*.pbxproj`. The other three rules are unrestricted.
- **32-hex is deliberately NOT a rule.** It is the shape of an R2 *access key id*, the public half of the pair, and it already has a hit in `README.md`.
- **Do not change the existing path check** (`^(\.agent-tasks/|inbox\.md$)`) or its message. The new block is additive.
- **`--no-verify` stays the documented override.**
- **Commit messages:** plain subject line, body only where it explains something the diff cannot. No tool attribution, no co-author trailers, no emoji.

---

### Task 1: The secret scan

**Files:**
- Modify: `.githooks/pre-commit` — extend the header comment, append the scan block

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing other code reads. The hook's contract is its exit code: `0` to allow, `1` to refuse.

- [ ] **Step 1: Extend the hook's header comment**

The file opens with a comment explaining that it refuses captured content. It now does two jobs, so say so. Insert this paragraph immediately before the `# Enable once per clone` block:

```bash
# It now does a second job. The path list above only ever covers the leak that
# already happened — it could not have seen the working Turso JWT and R2 secret
# key that sat inlined in four source files and reached this public repository.
# So the staged *content* is scanned too, for four credential shapes. That scan
# is a tripwire, not a proof: a credential in an unrecognised format, assigned
# to an unrecognised name, still passes.
```

- [ ] **Step 2: Append the scan block**

Add to the end of the file, after the existing `fi`:

```bash
# ---------------------------------------------------------------------------
# Secret scan over the staged *added* lines.
#
# Whole staged files are deliberately not scanned: a file that already contains
# a match would then block every future edit to it, and a hook people routinely
# bypass is worse than no hook — it trains the bypass.
#
# Every pattern is ERE, never PCRE. BSD grep has no `-P`, so a lookaround would
# make this hook behave differently depending on whether Homebrew's grep is
# earlier in PATH. The system grep is called explicitly for the same reason.

jwt_re='eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'
prov_re='(sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}|gsk_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})'
# Exactly 64 hex, not a slice of something longer. An R2 secret key is this
# shape — and so is every sha256 in pubspec.lock, which is why generated files
# are skipped for this rule and only this one.
hex_re='(^|[^0-9a-f])[0-9a-f]{64}([^0-9a-f]|$)'
# A secret-ish name, then `:` or `=`, then a quoted value. The only rule here
# that does not bet on a known shape.
ctx_re='(secret|token|password|passwd|api_?key|access_?key|auth_?token|auth_?key)[A-Za-z0-9_]*[[:space:]]*[:=][[:space:]]*r?("|'"'"')[^"'"'"'[:space:]]{16,}("|'"'"')'

GREP=/usr/bin/grep
[ -x "$GREP" ] || GREP=grep

findings=''

while IFS= read -r path; do
  [ -n "$path" ] || continue

  case "$path" in
    *.lock|.metadata|*Package.resolved|*.pbxproj) skip_hex=1 ;;
    *) skip_hex='' ;;
  esac

  # `-U0` means no context lines, so every `+` line is an addition. The awk
  # tracks the new-file line number from each hunk header and prints
  # "<line>:<content>". `+++ b/path` is a header, not an addition.
  added=$(git diff --cached -U0 -- "$path" | awk '
    /^\+\+\+/ { next }
    /^@@/ { if (match($0, /\+[0-9]+/)) n = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
    /^\+/ { print n ":" substr($0, 2); n++ }
  ')
  [ -n "$added" ] || continue

  for rule in jwt provider hex named; do
    flags=''
    case "$rule" in
      jwt)      re=$jwt_re ;;
      provider) re=$prov_re ;;
      hex)      [ -n "$skip_hex" ] && continue; re=$hex_re ;;
      named)    re=$ctx_re; flags='-i' ;;
    esac

    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      findings="${findings}  ${path}:${hit%%:*}  [${rule}]
"
    done < <(printf '%s\n' "$added" | $GREP -E $flags "$re" || true)
  done
done < <(git diff --cached --name-only --diff-filter=ACMR)

if [ -n "$findings" ]; then
  echo "pre-commit: refusing to commit what looks like a credential." >&2
  echo >&2
  echo "These staged lines match a credential shape. The value is deliberately" >&2
  echo "not printed — this repository is public, and echoing it here would put" >&2
  echo "it in your scrollback and shell history:" >&2
  echo >&2
  printf '%s' "$findings" >&2
  echo >&2
  echo "If it is a real credential: ROTATE IT. Unstaging is not enough once a" >&2
  echo "value has reached the working tree — it may already be in a build, a" >&2
  echo "log, or a screen share. This repository has paid that bill once." >&2
  echo >&2
  echo "If it is a false positive, commit with --no-verify." >&2
  exit 1
fi
```

- [ ] **Step 3: Check the script parses**

Run: `bash -n .githooks/pre-commit`
Expected: no output, exit 0. This catches a quoting error in `ctx_re`, which is the most fragile line in the file — it embeds both quote characters.

Then confirm the hook pins the system grep rather than inheriting whatever `PATH` offers:

Run: `grep -n 'GREP=/usr/bin/grep' .githooks/pre-commit`
Expected: one hit. Without it, a Homebrew grep earlier in `PATH` would silently accept PCRE syntax here and reject it on a clean machine.

Finally, confirm every pattern really is ERE by running them through BSD grep directly:

Run: `printf 'x eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJpYXQiOjF9.AbCdEfGhIjKl y\n' | /usr/bin/grep -cE 'eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'`
Expected: `1`.

- [ ] **Step 4: Prove each of the four rules fires**

The hook reads the index, so each check stages a scratch file, runs the hook directly, then unstages. Work in the repository root.

```bash
probe() {  # $1 = filename, $2 = line content
  printf '%s\n' "$2" > "$1"
  git add -f "$1"
  .githooks/pre-commit; echo "exit=$?"
  git restore --staged "$1"; /bin/rm -f "$1"
}
```

Run each and record the output:

```bash
probe probe.txt 'const t = "eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE3ODYxMDkwNDJ9.AbCdEfGhIjKl";'
probe probe.txt 'const k = "sk-AAAAAAAAAAAAAAAAAAAAAAAAAAAA";'
probe probe.txt 'const s = "b39624726eb42ac8074fb6f5e25f2a36b39624726eb42ac8074fb6f5e25f2a36";'
probe probe.txt 'password: "correcthorsebatterystaple";'
```

Expected: all four refuse with `exit=1`, and the four findings name `[jwt]`, `[provider]`, `[hex]`, `[named]` respectively. If any prints `exit=0`, that rule is dead — report it rather than adjusting the probe until it passes.

- [ ] **Step 5: Prove the real leak is caught**

This is the regression that matters. Stage the pre-fix content of the file that actually leaked:

```bash
git show 39a2070:lib/features/settings/presentation/qr_sync_sheet.dart > leak-probe.dart
git add -f leak-probe.dart
.githooks/pre-commit; echo "exit=$?"
git restore --staged leak-probe.dart; /bin/rm -f leak-probe.dart
```

Expected: refuses with `exit=1`, naming `[jwt]` and `[named]` and/or `[hex]` findings. If this passes, the hook does not solve the problem it was written for — stop and report.

- [ ] **Step 6: Prove `pubspec.lock` does not trip it**

This is the false positive that would get the hook switched off within a week — `pubspec.lock` holds 102 sha256 values, each 64 hex characters.

```bash
command cp -f pubspec.lock /tmp/pubspec.lock.bak
printf '      sha256: f5ff5b15620fbab8cb0849e9636c48e2b96c3f0f71723bbbe2ad3c761b205f05\n' >> pubspec.lock
git add pubspec.lock
.githooks/pre-commit; echo "exit=$?"
git restore --staged pubspec.lock
command cp -f /tmp/pubspec.lock.bak pubspec.lock
diff -q pubspec.lock /tmp/pubspec.lock.bak && /bin/rm -f /tmp/pubspec.lock.bak
```

Expected: `exit=0`. Note `cp`/`rm` are aliased interactively on this machine, hence `command cp -f` and `/bin/rm -f`; verify the restore with `diff -q` rather than trusting silence. Do **not** use `git checkout -- pubspec.lock` to restore — it reverts to `HEAD` and would take any other uncommitted change in that file with it.

- [ ] **Step 7: Prove the output contains no secret**

```bash
printf 'const s = "b39624726eb42ac8074fb6f5e25f2a36b39624726eb42ac8074fb6f5e25f2a36";\n' > probe.txt
git add -f probe.txt
.githooks/pre-commit 2>&1 | grep -c 'b39624726eb42ac8074fb6f5e25f2a36'
git restore --staged probe.txt; /bin/rm -f probe.txt
```

Expected: prints `0`. Any other number means the hook leaks the value it is refusing.

- [ ] **Step 8: Prove a clean commit still passes and the path rules still work**

```bash
printf 'clean file, nothing secret here\n' > probe.txt
git add -f probe.txt
.githooks/pre-commit; echo "clean exit=$?"
git restore --staged probe.txt; /bin/rm -f probe.txt

mkdir -p .agent-tasks && printf 'note\n' > .agent-tasks/probe.md
git add -f .agent-tasks/probe.md
.githooks/pre-commit; echo "path-rule exit=$?"
git restore --staged .agent-tasks/probe.md; /bin/rm -rf .agent-tasks/probe.md
```

Expected: `clean exit=0`, and `path-rule exit=1` refusing with the original captured-content message. The second confirms the new block did not break the old one.

- [ ] **Step 9: Confirm the tree is clean of probes**

Run: `git status --short`
Expected: only `.githooks/pre-commit` modified. Any leftover `probe.txt`, `leak-probe.dart` or `.agent-tasks/` entry means a cleanup above did not land.

- [ ] **Step 10: Run the project gate**

The hook is not Dart, so the suite cannot cover it — but the repository's gate must still be green before committing.

Run: `flutter test`
Expected: all passing.

Run: `flutter analyze`
Expected: no issues. (The baseline was clean as of `21c07f3`; anything reported is new and yours.)

- [ ] **Step 11: Commit**

```bash
git add .githooks/pre-commit
git commit -m "Scan staged content for credentials, not just paths

The path list only ever covers the leak that already happened. It could not
have seen the Turso JWT and R2 secret that sat inlined in four source files
and reached this public repository, and adding .wrangler/ last week was the
same shape of fix.

Four rules, each measured at zero false positives against the whole tree.
The 64-hex rule skips generated files because an R2 secret and a pubspec.lock
sha256 are the same 64 characters, and that rule alone would otherwise fire
102 times on one file.

Only added lines are scanned, and the refusal names the file and the rule but
never the value."
```

---

## After the plan

Two limits recorded so they are not mistaken for oversights:

- **This scans commits, not history.** Everything already pushed stays reachable through `refs/pull/*`; rotation remains the only remedy for what leaked.
- **Four shapes are not every shape.** A credential in an unrecognised format assigned to an unrecognised name passes, exactly as the language guard's wordlist half has false negatives by construction. The hook's own comment says so.
