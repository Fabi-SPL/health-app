-- v181 — the last unguarded trigger on a user-data table
--
-- Audit of every trigger function that writes into a table carrying CHECK or FK
-- constraints found exactly one without a catch-all handler:
-- parse_brain_dump_backlinks, which fires on brain_dumps INSERT/UPDATE and writes
-- into backlinks (FK to users, UNIQUE across five columns).
--
-- It has not fired a failure yet (backlinks holds 0 rows), but the exposure is
-- the same shape as v178: a convenience index built on top of a write, able to
-- take the write down with it. Brain dumps are Fabi's own words typed once. They
-- are not reproducible from anywhere.

CREATE OR REPLACE FUNCTION public.parse_brain_dump_backlinks()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  match record;
begin
  delete from public.backlinks where source_table = 'brain_dumps' and source_id = new.id;

  for match in
    select distinct unnest(regexp_matches(coalesce(new.content, ''), '\[\[([^\]]+)\]\]', 'g')) as needle
  loop
    insert into public.backlinks (user_id, source_table, source_id, target_table, target_id, match_text)
    select new.user_id, 'brain_dumps', new.id, 'tasks', t.id, match.needle
    from public.tasks t
    where t.user_id = new.user_id and lower(t.title) = lower(match.needle)
    on conflict do nothing;

    insert into public.backlinks (user_id, source_table, source_id, target_table, target_id, match_text)
    select new.user_id, 'brain_dumps', new.id, 'side_projects', sp.id, match.needle
    from public.side_projects sp
    where sp.user_id = new.user_id and lower(sp.title) = lower(match.needle)
    on conflict do nothing;
  end loop;

  for match in
    select distinct unnest(regexp_matches(coalesce(new.content, ''), '@([A-Za-zÀ-ÿ][A-Za-zÀ-ÿ0-9_\-\. ]{1,40})', 'g')) as needle
  loop
    insert into public.backlinks (user_id, source_table, source_id, target_table, target_id, match_text)
    select new.user_id, 'brain_dumps', new.id, 'people', p.id, match.needle
    from public.people p
    where p.user_id = new.user_id
      and (lower(p.name) = lower(trim(match.needle))
           or lower(p.name) like lower(trim(match.needle)) || ' %')
    on conflict do nothing;
  end loop;

  if new.primary_context_type is not null and new.primary_context_id is not null
     and new.primary_context_type != 'standalone' then
    insert into public.backlinks (user_id, source_table, source_id, target_table, target_id, match_text)
    values (new.user_id, 'brain_dumps', new.id, new.primary_context_type, new.primary_context_id, '__primary__')
    on conflict do nothing;
  end if;

  return new;

exception when others then
  -- a missing backlink is a missing convenience; a lost brain dump is lost words
  perform public.log_trigger_failure(new.user_id, 'parse_brain_dump_backlinks',
                                     sqlstate, sqlerrm);
  return new;
end;
$function$;
