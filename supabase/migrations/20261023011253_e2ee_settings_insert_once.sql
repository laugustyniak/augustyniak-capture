-- Zero-knowledge E2EE (issue #367): the KDF row is insert-once.
--
-- `user_e2ee_settings` holds the public half of the account key derivation.
-- Every device derives the key from the passphrase plus this row, and
-- `key_check_hash` is how a second device knows it derived the right one. The
-- client only ever inserts; an update would re-key the account under every
-- other device and leave the envelopes already in the cloud unreadable to
-- them. A leaked session must not be able to do with one PATCH what the client
-- never does, so UPDATE is withdrawn at the grant, the policy and the trigger
-- that only existed to guard it.

drop trigger if exists user_e2ee_settings_reject_owner_change on public.user_e2ee_settings;
drop policy if exists user_e2ee_settings_update_own on public.user_e2ee_settings;
revoke update on table public.user_e2ee_settings from authenticated;
