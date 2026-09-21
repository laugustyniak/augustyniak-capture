-- Version-gated push for the user-owned metadata tables (#194).
--
-- `security invoker`: every policy from the schema migration still applies,
-- so this function can only ever touch the caller's rows. `owner_id` is never
-- read from the payload — the column default fills it on insert and the
-- ownership trigger refuses a change on update. `updated_at` is likewise
-- ignored; the server stamps it.
--
-- For the six versioned tables a row is applied when it inserts, or when it
-- updates a row whose version is exactly one behind. A row that matches
-- nothing is returned in `conflicts` with the server's current row, so the
-- caller can resolve without a second round trip. `revisions` has no version
-- and no update grant: it inserts on its natural key and a repeat is a no-op.
--
-- Each row runs in its own subtransaction (a nested `begin … exception …
-- end`), so one bad row never aborts the batch. A row whose data is
-- malformed for its table — a missing not-null column, a bad foreign key, a
-- failed check constraint, a value that will not cast, an unknown column in
-- the payload, or (checked up front, before it can reach the SQL parser as a
-- malformed statement) a versioned-table row with no columns beyond its key
-- — is appended to `rejected` with its SQLSTATE instead. A permissions
-- failure (RLS, `insufficient_privilege`) and the `invalid_parameter_value`
-- this function itself raises are not in that list, so they propagate and
-- fail the call loudly.

create or replace function public.sync_push(table_name text, rows jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  key_columns text[];
  data_columns text[];
  row jsonb;
  applied integer := 0;
  conflicts jsonb := '[]'::jsonb;
  rejected jsonb := '[]'::jsonb;
  touched integer;
  current_row jsonb;
begin
  key_columns := case table_name
    when 'projects' then array['id']
    when 'recordings' then array['id']
    when 'segments' then array['recording_id', 'index']
    when 'clipboard_items' then array['id']
    when 'revisions' then array['recording_id', 'at', 'field']
    when 'devices' then array['id']
    when 'sync_state' then array['device_id', 'table_name']
    else null
  end;
  if key_columns is null then
    raise exception 'unknown table %', table_name
      using errcode = 'invalid_parameter_value';
  end if;

  if jsonb_typeof(rows) <> 'array' then
    raise exception 'rows must be a json array'
      using errcode = 'invalid_parameter_value';
  end if;

  for row in select value from jsonb_array_elements(rows)
  loop
    begin
      row := row - 'owner_id' - 'updated_at';
      select array_agg(k order by k) into data_columns
        from jsonb_object_keys(row) k;

      if table_name = 'revisions' then
        execute format(
          'insert into public.revisions (%s) select %s from jsonb_populate_record(null::public.revisions, $1) on conflict do nothing',
          (select string_agg(quote_ident(c), ', ') from unnest(data_columns) c),
          (select string_agg(quote_ident(c), ', ') from unnest(data_columns) c))
        using row;
        get diagnostics touched = row_count;
        applied := applied + touched;
        continue;
      end if;

      -- A row with no columns beyond its key would render `set` empty and
      -- fail to parse; caught here as a rejection rather than a syntax error
      -- that would abort the whole call.
      if not exists (
        select 1 from unnest(data_columns) c where c <> all (key_columns)
      ) then
        raise exception 'row for % has no columns beyond its key', table_name
          using errcode = 'not_null_violation';
      end if;

      execute format(
        'insert into public.%1$I (%2$s) select %2$s from jsonb_populate_record(null::public.%1$I, $1) '
        'on conflict (owner_id, %3$s) do update set %4$s '
        'where public.%1$I.version = excluded.version - 1',
        table_name,
        (select string_agg(quote_ident(c), ', ') from unnest(data_columns) c),
        (select string_agg(quote_ident(c), ', ') from unnest(key_columns) c),
        (select string_agg(format('%1$I = excluded.%1$I', c), ', ')
           from unnest(data_columns) c where c <> all (key_columns)))
      using row;
      get diagnostics touched = row_count;

      if touched = 1 then
        applied := applied + 1;
      else
        execute format(
          'select to_jsonb(t) from public.%1$I t where %2$s',
          table_name,
          (select string_agg(format('t.%1$I = ($1->>%2$L)::%3$s', c, c,
             format_type(a.atttypid, a.atttypmod)), ' and ')
             from unnest(key_columns) c
             join pg_attribute a on a.attname = c
              and a.attrelid = format('public.%I', table_name)::regclass))
        into current_row using row;
        conflicts := conflicts || coalesce(current_row, row);
      end if;
    exception
      when not_null_violation or foreign_key_violation or check_violation
        or invalid_text_representation or datatype_mismatch
        or undefined_column then
        rejected := rejected
          || jsonb_build_object('row', row, 'code', sqlstate);
    end;
  end loop;

  return jsonb_build_object(
    'applied', applied, 'conflicts', conflicts, 'rejected', rejected);
end;
$$;

revoke all on function public.sync_push(text, jsonb) from public, anon;
grant execute on function public.sync_push(text, jsonb) to authenticated;
