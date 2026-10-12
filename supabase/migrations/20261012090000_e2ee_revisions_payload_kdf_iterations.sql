-- E2EE envelope hardening (issue #298).
--
-- 1. `revisions` gains `encrypted_payload`. A revision's `from_value` and
--    `to_value` are the transcript, title or summary at two points in time —
--    the same content the recordings envelope exists for — and were the one
--    place that content still reached the server in the clear. The client now
--    seals both into the envelope and sends the two columns null; the columns
--    stay so a pre-E2EE client's rows and the pgTAP fixtures keep working.
--
-- 2. `user_e2ee_settings` gains `kdf_iterations`. The PBKDF2 count was a
--    client constant (100000); a server-side verifier is an offline guess
--    oracle by construction, so the count is the only cost between a leaked
--    row and the passphrase, and it has to be raisable. It now travels with
--    the salt: a second device derives with the count the key was set up
--    with, and new keys use the client's current default (600000). The column
--    default is the old constant so every row written before this migration
--    still describes its own key. The range mirrors the client's bound: a
--    value below it weakens the derivation, one above it pins a device's
--    unlock for hours — both are what a hostile row would carry. Named so a
--    later migration can raise the floor by dropping and re-adding it.

alter table public.revisions
  add column if not exists encrypted_payload text;

alter table public.user_e2ee_settings
  add column if not exists kdf_iterations integer not null default 100000
  constraint user_e2ee_settings_kdf_iterations_range
    check (kdf_iterations between 1000 and 10000000);
