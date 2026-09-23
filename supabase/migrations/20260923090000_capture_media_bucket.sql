-- Private Storage for capture media — slice 4 of #187 (#198).
--
-- One bucket, never public. An object's first folder is its owner's user id
-- (`<uid>/captures/<recording id>/<file name>`), and every policy compares
-- that folder with `auth.uid()`, so a client can only ever read or write under
-- its own prefix whatever key it sends.
--
-- Objects are write-once: there is no update policy, so an upload can never
-- replace a source another device already verified against its content hash.
-- There is no delete policy yet either — removing a tombstoned capture's
-- objects is a later change, and until then they stay private to their owner.

insert into storage.buckets (id, name, public)
values ('captures', 'captures', false)
on conflict (id) do nothing;

create policy captures_select_own on storage.objects
  for select to authenticated
  using (
    bucket_id = 'captures'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy captures_insert_own on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'captures'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
