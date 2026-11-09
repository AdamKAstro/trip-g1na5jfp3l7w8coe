-- Read-only checks after supabase/migrations/20261109133000_kids_share_links.sql.
-- Does not create users, links, or sessions.

do $check$
begin
  if to_regclass('public.child_links') is null then
    raise exception 'child_links is missing';
  end if;
  if not (select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.child_links'::regclass) then
    raise exception 'child_links is missing forced row level security';
  end if;
  if has_table_privilege('anon', 'public.child_links', 'SELECT')
     or has_table_privilege('authenticated', 'public.child_links', 'SELECT')
     or has_table_privilege('anon', 'public.child_links', 'INSERT') then
    raise exception 'child link hashes are readable or writable from the API';
  end if;
  if has_function_privilege('anon', 'public.issue_child_link(text)', 'EXECUTE') then
    raise exception 'anon can mint a child link';
  end if;
  if not has_function_privilege('anon', 'public.redeem_child_link(text)', 'EXECUTE') then
    raise exception 'anon cannot redeem a child link';
  end if;
  if not has_function_privilege('authenticated', 'public.issue_child_link(text)', 'EXECUTE') then
    raise exception 'parents cannot mint a child link';
  end if;
  if to_regprocedure('private.child_session_ok()') is null then
    raise exception 'child session check is missing';
  end if;
  if not exists (
    select 1 from pg_policy
    where polname = 'packing_child_session' and polrelid = 'public.packing_items'::regclass and not polpermissive
  ) then
    raise exception 'packing is missing the child session restriction';
  end if;
  if not exists (
    select 1 from pg_policy
    where polname = 'items_child_session' and polrelid = 'public.items'::regclass and not polpermissive
  ) then
    raise exception 'items are missing the child session restriction';
  end if;
  if (select pg_get_expr(polqual, polrelid) from pg_policy where polname = 'items_select' and polrelid = 'public.items'::regclass)
     is distinct from 'is_trip_member()' then
    raise exception 'items_select changed';
  end if;
end
$check$;
