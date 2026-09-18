# Supabase migration

## Status: In Progress

## Current Branch

`feat/187-google-login`

## Context

Issue #187 replaces client-held Turso and R2 credentials with Supabase Auth,
Postgres and Storage while preserving offline-first capture.

## Architecture Decisions

- Local SQLite and source files remain authoritative while offline.
- Supabase is optional until both public build-time values are present.
- Auth sessions and PKCE verifiers use the OS keyring with no plaintext fallback.
- Existing Turso/R2 sync remains available until metadata and media migrations
  have their own verified replacement.
- User ownership will be enforced by Postgres and Storage RLS, not client-side
  filters.

## Completed PRs

- [x] Auth/config foundation (#188)
- [x] Google sign-in and account state (current branch)
- [x] Link Supabase CLI and deploy the native callback allow-list
- [x] Configure and enable the Google provider in hosted Supabase Auth

## Next Steps

1. Add versioned Postgres schema, grants and RLS policies.
2. Replace pull-and-replace sync with an outbox, revisions and tombstones.
3. Move media to private Storage with resumable, hash-verified transfers.
4. Add the one-time, hash-verified local-library migration.

## Remaining live verification

- Complete one Google login in the installed desktop app and record the
  resulting owner UUID. New sign-ups can be disabled after that first account
  exists.
