-- Read-only checks to run AFTER supabase/migrations/20261109010000_kids_area.sql.
-- Safe to run in the Supabase SQL editor. It does not create users or change rows.
-- A failure here means the kids migration is missing or incomplete.

do $check$
declare
  v_src text;
begin
  if to_regclass('public.children') is null
     or to_regclass('public.packing_items') is null
     or to_regclass('public.trip_itinerary') is null
     or to_regclass('public.climate_normals') is null
     or to_regclass('public.climate_gaps') is null
     or to_regclass('public.packing_ops') is null
     or to_regclass('public.child_invites') is null then
    raise exception 'kids tables are missing';
  end if;

  if not (select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.packing_items'::regclass) then
    raise exception 'packing_items is missing forced row level security';
  end if;
  if not (select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.trip_itinerary'::regclass) then
    raise exception 'trip_itinerary is missing forced row level security';
  end if;

  if has_table_privilege('anon', 'public.packing_items', 'SELECT')
     or has_table_privilege('anon', 'public.trip_itinerary', 'SELECT')
     or has_table_privilege('anon', 'public.items', 'SELECT')
     or has_table_privilege('anon', 'public.child_invites', 'SELECT')
     or has_table_privilege('anon', 'public.packing_ops', 'SELECT') then
    raise exception 'anon can read family tables';
  end if;

  if has_table_privilege('authenticated', 'public.packing_items', 'INSERT')
     or has_table_privilege('authenticated', 'public.packing_items', 'UPDATE')
     or has_table_privilege('authenticated', 'public.packing_items', 'DELETE') then
    raise exception 'packing writes must go through apply_packing_op';
  end if;

  if not has_function_privilege('anon', 'public.claim_child_invite(text,text)', 'EXECUTE') then
    raise exception 'anon cannot claim an invite';
  end if;
  if has_function_privilege('anon', 'public.create_child_invite(text)', 'EXECUTE') then
    raise exception 'anon can create invites';
  end if;
  if has_function_privilege('anon', 'public.apply_packing_op(uuid,uuid,uuid,integer,text,integer,text,boolean,boolean,boolean)', 'EXECUTE') then
    raise exception 'anon can apply packing ops';
  end if;

  if not exists (select 1 from pg_policy where polname = 'items_no_child_role' and polrelid = 'public.items'::regclass) then
    raise exception 'items are not blocked for child role';
  end if;
  if not exists (select 1 from pg_policy where polname = 'suggestions_no_child_role' and polrelid = 'public.suggestions'::regclass) then
    raise exception 'suggestions are not blocked for child role';
  end if;

  select pg_get_functiondef('public.is_trip_member()'::regprocedure) into v_src;
  if v_src not like '%adamkiil79@gmail.com%' or v_src not like '%edware02@hotmail.com%' or v_src like '%liam@kids.usa-trip.invalid%' then
    raise exception 'is_trip_member() no longer matches the parent allow-list';
  end if;

  select pg_get_functiondef('public.block_other_signups()'::regprocedure) into v_src;
  if v_src not like '%Sign-ups are closed%' or v_src not like '%trip.allow_child_signup%' then
    raise exception 'signup block was not kept';
  end if;

  if (select count(*) from public.children) <> 4 then
    raise exception 'expected the four children';
  end if;
  if (select count(*) from public.trip_itinerary) < 18 then
    raise exception 'itinerary seed is missing rows';
  end if;
  if (select count(*) from public.packing_items) < 72 then
    raise exception 'starter packing rows are missing';
  end if;
  if (select high_c from public.climate_normals where place_key = 'nyc' and month = 12) is distinct from 7 then
    raise exception 'NYC December normal missing';
  end if;
  if not exists (select 1 from public.climate_gaps where place_key = 'cococay') then
    raise exception 'CocoCay gap row missing';
  end if;
  if exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'items'
  ) and not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'packing_items'
  ) then
    raise exception 'packing_items is not in the realtime publication';
  end if;
end
$check$;
