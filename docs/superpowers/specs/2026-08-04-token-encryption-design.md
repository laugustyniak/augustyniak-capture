# Token Encryption at Rest — Design

**Date:** 2026-08-04
**Status:** Approved
**Scope:** Encrypt provider `bearerToken` values currently stored as plaintext in `settings.json`.

## Problem

`ProviderProfile.bearerToken` is serialized verbatim into `settings.json`
(`lib/features/settings/domain/provider_profile.dart`), which lives in the app
documents directory. Any process or backup with file access reads API tokens in
the clear. The UI already warns about this (Models tab banner, Config tab
`•••• set (plaintext on disk)` badge); this design removes the underlying
exposure rather than the warning.

## Decisions

Three forks were decided during brainstorming:

1. **Approach:** envelope encryption — a random master key in the OS keyring,
   tokens encrypted in place inside `settings.json`. (Alternatives rejected:
   tokens fully in keyring — splits persistence into two stores with dangling
   entries and a second atomic-write path; app-level key file — obfuscation
   only.)
2. **Fallback:** when the keyring is unavailable, degrade to plaintext with a
   visible UI warning, matching the project's optional-processor/ffmpeg/xdotool
   degradation pattern. Never make transcription unusable over a missing
   keyring.
3. **Migration:** auto-migrate on first load. `load()` rewrites a
   plaintext-token `settings.json` once, encrypted, using the existing atomic
   write. If the keyring is unavailable, plaintext is left untouched and the
   migration retries on a later launch.

## Scheme

- One random 256-bit master key, generated on first use, stored in the OS
  keyring via `flutter_secure_storage` (libsecret on Linux, Keychain on iOS,
  Keystore on Android).
- Each `bearerToken` is encrypted with AES-256-GCM under that key, with a
  random 12-byte nonce per encryption.
- On-disk format: `enc:v1:<base64(nonce | ciphertext | tag)>` in the existing
  `bearerToken` JSON field. The prefix distinguishes encrypted from legacy
  plaintext values and versions the format for future migration. A user token
  that genuinely starts with `enc:v1:` is accepted as a non-risk.

## Architecture

New seam, same shape as `OcrService` / `ClipboardSink`:

- `TokenCipher` interface in `lib/features/settings/domain/token_cipher.dart`:
  - `Future<String> seal(String plaintext)`
  - `Future<String?> unseal(String stored)` — returns null on decrypt failure
  - `bool get isAvailable`
- Implementations in `lib/features/settings/data/`:
  - `KeyringTokenCipher` — master key via `flutter_secure_storage`; AES-GCM via
    the pure-Dart `cryptography` package (no platform channel for the crypto
    itself, so the cipher logic is testable without a binding).
  - `PlaintextTokenCipher` — identity transform; used as the runtime fallback
    and the test default.

**Layering rule:** the domain layer (`ProviderProfile`, `AppSettings`) stays
untouched and synchronous. `toJson`/`fromJson` continue to read and write the
raw string. The cipher applies at the repository boundary only:

- `SettingsRepository.save()` seals every profile token before writing.
- `SettingsRepository.load()` unseals after parsing.
- In-memory `AppSettings` always holds plaintext tokens — the HTTP
  `Authorization` header needs them anyway.

`SettingsRepository` gains a constructor-injected `TokenCipher` (defaulting to
`PlaintextTokenCipher`), so `_FakeSettingsRepository`-style tests are
unaffected.

## Startup wiring

The shell (which already builds platform impls per OS) probes the keyring once
at startup with a write/read round trip:

- Probe succeeds → `KeyringTokenCipher`.
- Probe fails (no gnome-keyring, locked Secret Service, headless session) →
  `PlaintextTokenCipher`.

The chosen cipher's availability drives the UI copy:

- Config tab badge: `•••• encrypted at rest` vs
  `•••• set (plaintext — keyring unavailable)`.
- Models tab banner updated with the same distinction.

## Failure behavior

- **Keyring key lost** (keyring wiped/reset): `unseal` returns null; the
  profile behaves tokenless for the session. Requests fail with 401, items land
  `failed` and stay retryable — the existing failure model. The encrypted blob
  is **never deleted or overwritten with null** on decrypt failure, so the
  token recovers if the keyring returns.
- **Keyring unavailable at save time** with an already-encrypted token in
  memory-from-disk: not possible — load unseals to plaintext or null; save
  through `PlaintextTokenCipher` writes what is in memory. A null-token session
  therefore must not rewrite the stored blob: `save()` preserves the original
  stored value for any profile whose token failed to unseal this session.

## Migration detail

In `load()`, after parsing succeeds:

1. If the cipher `isAvailable` and any profile token lacks the `enc:` prefix,
   re-save immediately (seals all tokens) using the existing `.tmp` + rename.
2. If the cipher is unavailable, do nothing; plaintext stays until a launch
   where the keyring works.

`--dart-define` seeding (`TRANSCRIPTION_TOKEN`) is unchanged: it seeds the
first profile in memory; the token is sealed at the first save.

## Dependencies and documentation

- `pubspec.yaml`: add `flutter_secure_storage`, `cryptography`.
- Linux: `libsecret-1-dev` required at build time, gnome-keyring wanted at
  runtime. Documented in CLAUDE.md and README next to the keybinder note.

## Testing

Pure-Dart where possible, per project convention:

- `TokenCipher` seal/unseal round trip (using `cryptography` directly with an
  in-memory key store fake — no `flutter_secure_storage` in tests).
- Legacy plaintext `settings.json` auto-migrates on load; file on disk gains
  `enc:v1:` prefixes.
- Cipher unavailable: load leaves plaintext untouched; save writes plaintext.
- Unseal failure: in-memory token is null; stored blob preserved across a
  subsequent save.
- Prefix detection: plaintext, encrypted, and empty/null tokens each route
  correctly.
- Existing settings round-trip and legacy-defaults tests keep passing.
