-- Kids itinerary + packing. Additive.
-- Coordinator: run this whole file once on project zfgdqsoibiaclwpothio.
-- Do not put the service role key in the website. Kids sign in with their own accounts.
-- Re-running is safe for itinerary and packing seeds (existing rows are left alone).
-- Climate rows are refreshed in place. They are not copied onto itinerary rows.
--
-- Unchanged: public.is_trip_member(), public.items_stamp(), public.suggestions_guard(),
-- the items_stamp and suggestions_guard triggers, and the existing items/suggestions policies
-- (items_select, items_update, suggestions_select, suggestions_insert, suggestions_update_own_new,
-- suggestions_delete_own_new). Those policies already require is_trip_member(), which is only
-- the two parent emails, so a child account does not satisfy them.
-- Added: restrictive policies so a JWT with app_metadata.trip_role = child is refused on
-- items and suggestions even if that email were later added to is_trip_member().
-- Replaced: public.block_other_signups() only. The trigger on auth.users stays. Parent emails
-- are still accepted. Any other email is still rejected unless this migration's claim function
-- has set a transaction-local flag AND the new row is one of the four child addresses with
-- trip_role child. A child row cannot be inserted as a parent.

begin;

do $guard$
begin
  if to_regprocedure('public.is_trip_member()') is null then
    raise exception 'is_trip_member() is missing; refusing to continue';
  end if;
  if to_regclass('public.items') is null or to_regclass('public.suggestions') is null then
    raise exception 'public.items or public.suggestions is missing; refusing to continue';
  end if;
end
$guard$;

create schema if not exists extensions;
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to anon, authenticated;

create extension if not exists pgcrypto with schema extensions;

-- Parents stay exactly the two existing emails. A child JWT is refused even if that list changes later.
drop policy if exists items_no_child_role on public.items;
create policy items_no_child_role on public.items
  as restrictive for all to authenticated
  using (coalesce(auth.jwt() -> 'app_metadata' ->> 'trip_role', '') is distinct from 'child')
  with check (coalesce(auth.jwt() -> 'app_metadata' ->> 'trip_role', '') is distinct from 'child');

drop policy if exists suggestions_no_child_role on public.suggestions;
create policy suggestions_no_child_role on public.suggestions
  as restrictive for all to authenticated
  using (coalesce(auth.jwt() -> 'app_metadata' ->> 'trip_role', '') is distinct from 'child')
  with check (coalesce(auth.jwt() -> 'app_metadata' ->> 'trip_role', '') is distinct from 'child');

-- Still closed to the public. The claim function sets trip.allow_child_signup for its own insert only.
create or replace function public.block_other_signups()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if lower(coalesce(new.email, '')) in ('adamkiil79@gmail.com', 'edware02@hotmail.com') then
    return new;
  end if;
  if pg_catalog.current_setting('trip.allow_child_signup', true) = 'on'
     and lower(coalesce(new.email, '')) in (
       'liam@kids.usa-trip.invalid',
       'ana@kids.usa-trip.invalid',
       'harriet@kids.usa-trip.invalid',
       'claudia@kids.usa-trip.invalid'
     )
     and coalesce(new.raw_app_meta_data ->> 'trip_role', '') = 'child'
  then
    return new;
  end if;
  raise exception 'Sign-ups are closed';
end
$fn$;

create table if not exists public.children (
  id uuid primary key,
  slug text not null unique check (slug in ('liam', 'ana', 'harriet', 'claudia')),
  display_name text not null,
  sort integer not null unique check (sort between 1 and 4),
  email text not null unique,
  user_id uuid unique references auth.users (id),
  created_at timestamptz not null default pg_catalog.now()
);

create table if not exists public.child_invites (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children (id),
  code_hash text not null unique,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default pg_catalog.now()
);

create table if not exists public.trip_itinerary (
  id uuid primary key,
  starts_on date not null,
  ends_on date,
  title text not null check (char_length(btrim(title)) between 1 and 140),
  summary text check (summary is null or char_length(summary) <= 400),
  place_key text check (place_key is null or place_key ~ '^[a-z0-9-]{1,40}$'),
  sort integer not null,
  updated_at timestamptz not null default pg_catalog.now(),
  check (ends_on is null or ends_on >= starts_on)
);

create table if not exists public.climate_normals (
  place_key text not null,
  month integer not null check (month between 1 and 12),
  high_c integer not null,
  low_c integer not null,
  source_high text not null,
  source_low text not null,
  period text not null,
  station text not null,
  station_id text,
  source_name text not null,
  source_url text not null,
  source_data_url text,
  kind text not null,
  note text not null,
  primary key (place_key, month),
  check (high_c > low_c)
);

create table if not exists public.climate_gaps (
  place_key text primary key,
  reason text not null
);

create table if not exists public.packing_items (
  id uuid primary key,
  child_id uuid not null references public.children (id),
  title text not null check (char_length(btrim(title)) between 1 and 140),
  qty integer check (qty is null or qty between 1 and 99),
  category text check (category is null or char_length(btrim(category)) between 1 and 40),
  checked boolean not null default false,
  deleted_at timestamptz,
  suggested boolean not null default false,
  version integer not null default 1 check (version >= 1),
  updated_at timestamptz not null default pg_catalog.now()
);

create table if not exists public.packing_ops (
  op_id uuid primary key,
  item_id uuid not null,
  child_id uuid not null references public.children (id),
  result jsonb not null,
  created_at timestamptz not null default pg_catalog.now()
);

create index if not exists packing_items_child_updated_idx on public.packing_items (child_id, updated_at);
create index if not exists child_invites_child_idx on public.child_invites (child_id);

alter table public.packing_items replica identity full;
alter table public.trip_itinerary replica identity full;

create or replace function public.is_child_self(p_child uuid)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $fn$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'trip_role', '') = 'child'
    and coalesce(auth.jwt() -> 'app_metadata' ->> 'child_id', '') ~* '^[0-9a-f-]{36}$'
    and (auth.jwt() -> 'app_metadata' ->> 'child_id')::uuid = p_child
$fn$;

create or replace function public.touch_itinerary()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $fn$
begin
  new.updated_at := pg_catalog.clock_timestamp();
  return new;
end
$fn$;

drop trigger if exists trip_itinerary_touch on public.trip_itinerary;
create trigger trip_itinerary_touch before update on public.trip_itinerary
  for each row execute function public.touch_itinerary();

create or replace function private.packing_json(r public.packing_items)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $fn$
  select pg_catalog.jsonb_build_object(
    'id', r.id,
    'child_id', r.child_id,
    'title', r.title,
    'qty', r.qty,
    'category', r.category,
    'checked', r.checked,
    'deleted_at', r.deleted_at,
    'suggested', r.suggested,
    'version', r.version,
    'updated_at', r.updated_at
  )
$fn$;

create or replace function private.apply_packing_op(
  p_op_id uuid,
  p_item_id uuid,
  p_child_id uuid,
  p_base_version integer,
  p_title text,
  p_qty integer,
  p_category text,
  p_checked boolean,
  p_deleted boolean,
  p_suggested boolean
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_existing jsonb;
  v_row public.packing_items%rowtype;
  v_title text;
  v_category text;
  v_result jsonb;
begin
  select result into v_existing from public.packing_ops where op_id = p_op_id;
  if found then
    select * into v_row from public.packing_items where id = p_item_id;
    return pg_catalog.jsonb_build_object(
      'status', 'duplicate',
      'item', case when found then private.packing_json(v_row) else v_existing -> 'item' end
    );
  end if;

  if not (public.is_trip_member() or public.is_child_self(p_child_id)) then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  v_title := pg_catalog.btrim(coalesce(p_title, ''));
  v_category := nullif(pg_catalog.btrim(coalesce(p_category, '')), '');
  if coalesce(p_deleted, false) = false and (char_length(v_title) < 1 or char_length(v_title) > 140) then
    raise exception 'bad packing' using errcode = '22023';
  end if;
  if p_deleted = true and char_length(v_title) > 140 then
    raise exception 'bad packing' using errcode = '22023';
  end if;
  if p_qty is not null and (p_qty < 1 or p_qty > 99) then
    raise exception 'bad packing' using errcode = '22023';
  end if;
  if v_category is not null and char_length(v_category) > 40 then
    raise exception 'bad packing' using errcode = '22023';
  end if;

  select * into v_row from public.packing_items where id = p_item_id for update;

  if not found then
    if coalesce(p_deleted, false) then
      v_result := pg_catalog.jsonb_build_object('status', 'applied', 'item', null);
    elsif p_base_version is not null then
      v_result := pg_catalog.jsonb_build_object('status', 'conflict', 'item', null);
    else
      insert into public.packing_items (id, child_id, title, qty, category, checked, deleted_at, suggested, version, updated_at)
      values (
        p_item_id, p_child_id, v_title, p_qty, v_category, coalesce(p_checked, false),
        null, coalesce(p_suggested, false), 1, pg_catalog.clock_timestamp()
      )
      returning * into v_row;
      v_result := pg_catalog.jsonb_build_object('status', 'applied', 'item', private.packing_json(v_row));
    end if;
  else
    if v_row.child_id is distinct from p_child_id then
      raise exception 'not allowed' using errcode = '42501';
    end if;
    if p_base_version is distinct from v_row.version then
      v_result := pg_catalog.jsonb_build_object('status', 'conflict', 'item', private.packing_json(v_row));
    else
      update public.packing_items set
        title = case when char_length(v_title) >= 1 then v_title else title end,
        qty = p_qty,
        category = v_category,
        checked = coalesce(p_checked, false),
        deleted_at = case when coalesce(p_deleted, false) then coalesce(deleted_at, pg_catalog.clock_timestamp()) else null end,
        suggested = coalesce(p_suggested, suggested),
        version = version + 1,
        updated_at = pg_catalog.clock_timestamp()
      where id = p_item_id
      returning * into v_row;
      v_result := pg_catalog.jsonb_build_object('status', 'applied', 'item', private.packing_json(v_row));
    end if;
  end if;

  insert into public.packing_ops (op_id, item_id, child_id, result)
  values (p_op_id, p_item_id, p_child_id, v_result);
  return v_result;
exception
  when unique_violation then
    select result into v_existing from public.packing_ops where op_id = p_op_id;
    if found then
      return v_existing;
    end if;
    select * into v_row from public.packing_items where id = p_item_id;
    return pg_catalog.jsonb_build_object('status', 'conflict', 'item', case when found then private.packing_json(v_row) else null end);
end
$fn$;

create or replace function public.apply_packing_op(
  p_op_id uuid,
  p_item_id uuid,
  p_child_id uuid,
  p_base_version integer,
  p_title text,
  p_qty integer,
  p_category text,
  p_checked boolean,
  p_deleted boolean,
  p_suggested boolean
) returns jsonb
language sql
security invoker
set search_path = ''
as $fn$
  select private.apply_packing_op(
    p_op_id, p_item_id, p_child_id, p_base_version,
    p_title, p_qty, p_category, p_checked, p_deleted, p_suggested
  )
$fn$;

create table if not exists private.claim_attempts (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default pg_catalog.now(),
  ok boolean not null
);
alter table private.claim_attempts enable row level security;
alter table private.claim_attempts force row level security;
revoke all on table private.claim_attempts from public, anon, authenticated;

-- Expected failures return jsonb instead of raising, so the attempt row commits
-- with the PostgREST transaction. The guess itself is not stored.
create or replace function private.claim_limited(p_message text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_n integer;
begin
  delete from private.claim_attempts where created_at < pg_catalog.now() - interval '30 minutes';
  select count(*) into v_n from private.claim_attempts
  where ok = false and created_at > pg_catalog.now() - interval '10 minutes';
  if v_n >= 30 then
    return pg_catalog.jsonb_build_object('error', 'Too many attempts. Wait a few minutes and try again.');
  end if;
  insert into private.claim_attempts (ok) values (false);
  return pg_catalog.jsonb_build_object('error', p_message);
end
$fn$;
revoke all on function private.claim_limited(text) from public, anon, authenticated;

create or replace function private.claim_child_invite(p_code text, p_password text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_code text;
  v_hash text;
  v_inv public.child_invites%rowtype;
  v_child public.children%rowtype;
  v_user auth.users%rowtype;
  v_meta jsonb;
begin
  if p_password is null or char_length(p_password) < 8 or char_length(p_password) > 72 then
    return private.claim_limited('Choose a password of 8 to 72 characters');
  end if;
  v_code := upper(pg_catalog.regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if char_length(v_code) < 16 then
    return private.claim_limited('That code is not valid');
  end if;
  v_hash := encode(extensions.digest(v_code, 'sha256'), 'hex');
  select * into v_inv from public.child_invites where code_hash = v_hash for update;
  if not found then
    return private.claim_limited('That code is not valid');
  end if;
  if v_inv.used_at is not null then
    return private.claim_limited('That code has already been used');
  end if;
  if v_inv.expires_at <= pg_catalog.now() then
    return private.claim_limited('That code has expired');
  end if;
  select * into v_child from public.children where id = v_inv.child_id;
  if not found then
    return private.claim_limited('That code is not valid');
  end if;

  select * into v_user from auth.users where lower(email) = lower(v_child.email);
  v_meta := pg_catalog.jsonb_build_object(
    'provider', 'email',
    'providers', pg_catalog.jsonb_build_array('email'),
    'trip_role', 'child',
    'child_id', v_child.id::text,
    'child_slug', v_child.slug
  );

  if found then
    if coalesce(v_user.raw_app_meta_data ->> 'trip_role', '') is distinct from 'child' then
      return private.claim_limited('Sign-ups are closed');
    end if;
    update auth.users set
      encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
      raw_app_meta_data = v_meta,
      email_confirmed_at = coalesce(email_confirmed_at, pg_catalog.now()),
      updated_at = pg_catalog.now()
    where id = v_user.id;
  else
    v_user.id := gen_random_uuid();
    perform pg_catalog.set_config('trip.allow_child_signup', 'on', true);
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change,
      email_change_token_current, phone_change, phone_change_token, reauthentication_token,
      is_sso_user, is_anonymous
    ) values (
      '00000000-0000-0000-0000-000000000000',
      v_user.id,
      'authenticated',
      'authenticated',
      v_child.email,
      extensions.crypt(p_password, extensions.gen_salt('bf')),
      pg_catalog.now(),
      v_meta,
      pg_catalog.jsonb_build_object('display_name', v_child.display_name),
      pg_catalog.now(),
      pg_catalog.now(),
      '', '', '', '',
      '', '', '', '',
      false,
      false
    );
    insert into auth.identities (
      id, user_id, identity_data, provider, provider_id, email, created_at, updated_at
    ) values (
      gen_random_uuid(),
      v_user.id,
      pg_catalog.jsonb_build_object('sub', v_user.id::text, 'email', v_child.email, 'email_verified', true),
      'email',
      v_user.id::text,
      v_child.email,
      pg_catalog.now(),
      pg_catalog.now()
    );
  end if;

  update public.children set user_id = v_user.id where id = v_child.id and (user_id is null or user_id = v_user.id);
  update public.child_invites set used_at = pg_catalog.now() where id = v_inv.id;
  return pg_catalog.jsonb_build_object('email', v_child.email, 'display_name', v_child.display_name);
end
$fn$;

create or replace function public.claim_child_invite(p_code text, p_password text)
returns jsonb
language sql
security invoker
set search_path = ''
as $fn$
  select private.claim_child_invite(p_code, p_password)
$fn$;

create or replace function private.create_child_invite(p_slug text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_child public.children%rowtype;
  v_raw text := '';
  v_byte integer;
  v_code text;
  v_hash text;
  v_expires timestamptz;
  v_alpha text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if not public.is_trip_member() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into v_child from public.children where slug = p_slug;
  if not found then
    raise exception 'Unknown child';
  end if;
  update public.child_invites set used_at = pg_catalog.now()
  where child_id = v_child.id and used_at is null;

  while char_length(v_raw) < 20 loop
    v_byte := get_byte(extensions.gen_random_bytes(1), 0);
    v_raw := v_raw || substr(v_alpha, 1 + (v_byte % 32), 1);
  end loop;
  v_code := substr(v_raw, 1, 4) || '-' || substr(v_raw, 5, 4) || '-' || substr(v_raw, 9, 4) || '-' || substr(v_raw, 13, 4) || '-' || substr(v_raw, 17, 4);
  v_hash := encode(extensions.digest(v_raw, 'sha256'), 'hex');
  v_expires := pg_catalog.now() + interval '7 days';
  insert into public.child_invites (child_id, code_hash, expires_at, created_by)
  values (v_child.id, v_hash, v_expires, auth.uid());
  return pg_catalog.jsonb_build_object(
    'code', v_code,
    'email', v_child.email,
    'display_name', v_child.display_name,
    'expires_at', v_expires
  );
end
$fn$;

create or replace function public.create_child_invite(p_slug text)
returns jsonb
language sql
security invoker
set search_path = ''
as $fn$
  select private.create_child_invite(p_slug)
$fn$;

create or replace function public.my_access()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $fn$
declare
  v_id text;
  v_row public.children%rowtype;
begin
  if public.is_trip_member() then
    return pg_catalog.jsonb_build_object('role', 'parent');
  end if;
  if coalesce(auth.jwt() -> 'app_metadata' ->> 'trip_role', '') is distinct from 'child' then
    return pg_catalog.jsonb_build_object('role', 'none');
  end if;
  v_id := coalesce(auth.jwt() -> 'app_metadata' ->> 'child_id', '');
  if v_id !~* '^[0-9a-f-]{36}$' then
    return pg_catalog.jsonb_build_object('role', 'none');
  end if;
  select * into v_row from public.children where id = v_id::uuid;
  if not found then
    return pg_catalog.jsonb_build_object('role', 'none');
  end if;
  return pg_catalog.jsonb_build_object(
    'role', 'child',
    'child_id', v_row.id,
    'slug', v_row.slug,
    'display_name', v_row.display_name
  );
end
$fn$;

create or replace function private.seed_kids_content()
returns void
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  insert into public.children (id, slug, display_name, sort, email) values
    ('c0a1d000-0000-4000-8000-000000000001', 'liam', 'Liam', 1, 'liam@kids.usa-trip.invalid'),
    ('c0a1d000-0000-4000-8000-000000000002', 'ana', 'Ana', 2, 'ana@kids.usa-trip.invalid'),
    ('c0a1d000-0000-4000-8000-000000000003', 'harriet', 'Harriet', 3, 'harriet@kids.usa-trip.invalid'),
    ('c0a1d000-0000-4000-8000-000000000004', 'claudia', 'Claudia', 4, 'claudia@kids.usa-trip.invalid')
  on conflict (id) do update set
    display_name = excluded.display_name,
    email = excluded.email,
    sort = excluded.sort;

  insert into public.trip_itinerary (id, starts_on, ends_on, title, summary, place_key, sort) values
    ('a1000000-0000-4000-8000-000000000001', '2026-12-10', '2026-12-13', 'Singapore', 'Fly in on 10 December and stay until the late flight out on 13 December.', 'singapore', 10),
    ('a1000000-0000-4000-8000-000000000002', '2026-12-14', '2026-12-19', 'New York', 'Land in Newark early on 14 December. These are the city days before the drive north.', 'nyc', 20),
    ('a1000000-0000-4000-8000-000000000003', '2026-12-20', '2026-12-23', 'Vermont ski', 'Drive up on 20 December for Mount Snow, and head back before Christmas.', 'vermont', 30),
    ('a1000000-0000-4000-8000-000000000004', '2026-12-24', '2026-12-25', 'Christmas in New York', 'Christmas Eve in the city, and Christmas Day lunch at Tavern on the Green.', 'nyc', 40),
    ('a1000000-0000-4000-8000-000000000005', '2026-12-26', '2026-12-28', 'Washington, DC', 'Train down on 26 December.', 'dc', 50),
    ('a1000000-0000-4000-8000-000000000006', '2026-12-29', '2026-12-29', 'Miami', 'Fly to Miami on 29 December.', 'miami', 60),
    ('a1000000-0000-4000-8000-000000000007', '2027-01-01', '2027-01-01', 'Sebastian', 'Morning on the water on 1 January. Other east-coast nights were still being settled, so they are not listed.', 'vero', 70),
    ('a1000000-0000-4000-8000-000000000008', '2027-01-02', '2027-01-02', 'Cocoa Beach', 'The night before the ship, near Port Canaveral.', 'cocoa', 80),
    ('a1000000-0000-4000-8000-000000000009', '2027-01-03', '2027-01-03', 'Board the ship', 'Port Canaveral in the afternoon. Star of the Seas sails on 3 January.', 'cocoa', 90),
    ('a1000000-0000-4000-8000-000000000010', '2027-01-04', '2027-01-04', 'At sea', 'A day on the ship.', 'sea', 100),
    ('a1000000-0000-4000-8000-000000000011', '2027-01-05', '2027-01-05', 'Costa Maya', 'Mexico port day. Published clock times do not match each other, so no arrival time is shown.', 'costa-maya', 110),
    ('a1000000-0000-4000-8000-000000000012', '2027-01-06', '2027-01-06', 'Roatan', 'Honduras port day.', 'roatan', 120),
    ('a1000000-0000-4000-8000-000000000013', '2027-01-07', '2027-01-07', 'Cozumel', 'Mexico port day.', 'cozumel', 130),
    ('a1000000-0000-4000-8000-000000000014', '2027-01-08', '2027-01-08', 'At sea', 'A day on the ship.', 'sea', 140),
    ('a1000000-0000-4000-8000-000000000015', '2027-01-09', '2027-01-09', 'CocoCay', 'The ship''s island day in the Bahamas.', 'cococay', 150),
    ('a1000000-0000-4000-8000-000000000016', '2027-01-10', '2027-01-10', 'Universal Orlando', 'The ship docks at Port Canaveral in the morning. The plan for the day is Universal.', 'orlando', 160),
    ('a1000000-0000-4000-8000-000000000017', '2027-01-11', '2027-01-11', 'Travel day', 'Leave Orlando and connect on to the long flight home.', 'travel', 170),
    ('a1000000-0000-4000-8000-000000000018', '2027-01-13', '2027-01-13', 'Singapore, then home', 'Morning arrival in Singapore, then the flight home.', 'singapore', 180)
  on conflict (id) do nothing;

  insert into public.climate_normals (
    place_key, month, high_c, low_c, source_high, source_low, period, station, station_id, source_name, source_url, source_data_url, kind, note
  ) values
    ('singapore', 12, 30, 24, '30.2°C', '24.0°C', '1982–2008', 'Changi climate station', null, 'NEA Guidebook on Climate of Singapore', 'https://www.nea.gov.sg/docs/default-source/resource/guidebook-on-climate-of-singapore.pdf', null, 'Mean daily maximum and mean daily minimum', 'Rounded to the nearest °C. Seasonal average, not a forecast.'),
    ('singapore', 1, 30, 24, '30.3°C', '23.9°C', '1982–2008', 'Changi climate station', null, 'NEA Guidebook on Climate of Singapore', 'https://www.nea.gov.sg/docs/default-source/resource/guidebook-on-climate-of-singapore.pdf', null, 'Mean daily maximum and mean daily minimum', 'Rounded to the nearest °C. Seasonal average, not a forecast.'),
    ('nyc', 12, 7, 1, '44.3°F', '33.8°F', '1991–2020', 'New York Central Park Tower, NY (USW00094728)', 'USW00094728', 'NOAA NCEI U.S. Climate Normals', 'https://www.ncei.noaa.gov/products/land-based-station/us-climate-normals', 'https://www.ncei.noaa.gov/access/services/data/v1?dataset=normals-monthly-1991-2020&stations=USW00094728', 'Mean daily maximum and mean daily minimum', 'Rounded to the nearest °C. Seasonal average, not a forecast.'),
    ('vermont', 12, 3, -6, '37.5°F', '20.6°F', '1991–2020', 'Bennington Morse State Airport, VT (USW00054781)', 'USW00054781', 'NOAA NCEI U.S. Climate Normals', 'https://www.ncei.noaa.gov/products/land-based-station/us-climate-normals', 'https://www.ncei.noaa.gov/access/services/data/v1?dataset=normals-monthly-1991-2020&stations=USW00054781', 'Mean daily maximum and mean daily minimum', 'Airport station, not the Mount Snow summit. Rounded to the nearest °C. Seasonal average, not a forecast.'),
    ('dc', 12, 9, 1, '48.8°F', '34.5°F', '1991–2020', 'Washington Reagan Airport, VA (USW00013743)', 'USW00013743', 'NOAA NCEI U.S. Climate Normals', 'https://www.ncei.noaa.gov/products/land-based-station/us-climate-normals', 'https://www.ncei.noaa.gov/access/services/data/v1?dataset=normals-monthly-1991-2020&stations=USW00013743', 'Mean daily maximum and mean daily minimum', 'Rounded to the nearest °C. Seasonal average, not a forecast.'),
    ('miami', 12, 26, 18, '78.2°F', '64.3°F', '1991–2020', 'Miami International Airport, FL (USW00012839)', 'USW00012839', 'NOAA NCEI U.S. Climate Normals', 'https://www.ncei.noaa.gov/products/land-based-station/us-climate-normals', 'https://www.ncei.noaa.gov/access/services/data/v1?dataset=normals-monthly-1991-2020&stations=USW00012839', 'Mean daily maximum and mean daily minimum', 'Rounded to the nearest °C. Seasonal average, not a forecast.'),
    ('vero', 12, 24, 13, '75.4°F', '56.1°F', '1991–2020', 'Vero Beach International Airport, FL (USW00012843)', 'USW00012843', 'NOAA NCEI U.S. Climate Normals', 'https://www.ncei.noaa.gov/products/land-based-station/us-climate-normals', 'https://www.ncei.noaa.gov/access/services/data/v1?dataset=normals-monthly-1991-2020&stations=USW00012843', 'Mean daily maximum and mean daily minimum', 'Rounded to the nearest °C. Seasonal average, not a forecast.'),
    ('vero', 1, 23, 11, '73.3°F', '52.2°F', '1991–2020', 'Vero Beach International Airport, FL (USW00012843)', 'USW00012843', 'NOAA NCEI U.S. Climate Normals', 'https://www.ncei.noaa.gov/products/land-based-station/us-climate-normals', 'https://www.ncei.noaa.gov/access/services/data/v1?dataset=normals-monthly-1991-2020&stations=USW00012843', 'Mean daily maximum and mean daily minimum', 'Rounded to the nearest °C. Seasonal average, not a forecast.'),
    ('cocoa', 1, 22, 11, '71.8°F', '51.7°F', '1991–2020', 'Melbourne International Airport, FL (USW00012838)', 'USW00012838', 'NOAA NCEI U.S. Climate Normals', 'https://www.ncei.noaa.gov/products/land-based-station/us-climate-normals', 'https://www.ncei.noaa.gov/access/services/data/v1?dataset=normals-monthly-1991-2020&stations=USW00012838', 'Mean daily maximum and mean daily minimum', 'Rounded to the nearest °C. Seasonal average, not a forecast.'),
    ('orlando', 1, 22, 10, '71.8°F', '49.5°F', '1991–2020', 'Orlando International Airport, FL (USW00012815)', 'USW00012815', 'NOAA NCEI U.S. Climate Normals', 'https://www.ncei.noaa.gov/products/land-based-station/us-climate-normals', 'https://www.ncei.noaa.gov/access/services/data/v1?dataset=normals-monthly-1991-2020&stations=USW00012815', 'Mean daily maximum and mean daily minimum', 'Rounded to the nearest °C. Seasonal average, not a forecast.')
  on conflict (place_key, month) do update set
    high_c = excluded.high_c,
    low_c = excluded.low_c,
    source_high = excluded.source_high,
    source_low = excluded.source_low,
    period = excluded.period,
    station = excluded.station,
    station_id = excluded.station_id,
    source_name = excluded.source_name,
    source_url = excluded.source_url,
    source_data_url = excluded.source_data_url,
    kind = excluded.kind,
    note = excluded.note;

  insert into public.climate_gaps (place_key, reason) values
    ('costa-maya', 'No 1991–2020 climate-normal station for the Costa Maya pier was used. A nearby inland town was not substituted.'),
    ('roatan', 'No 1991–2020 climate-normal station for Roatan was found in the NOAA U.S. normals used for the other stops, so no number is shown.'),
    ('cozumel', 'No 1991–2020 climate-normal station for Cozumel was found in the NOAA U.S. normals used for the other stops, so no number is shown.'),
    ('cococay', 'CocoCay has no public climate-normal station. Nassau is a different island, so its temperatures are not shown here.'),
    ('sea', 'A day at sea has no port weather station on this screen.'),
    ('travel', 'This is a travel day, so there is no single place to attach a temperature.')
  on conflict (place_key) do update set reason = excluded.reason;

  insert into public.packing_items (id, child_id, title, category, suggested, checked, version)
  select (
      'b0000001-0000-4000-8000-' || lpad(c.sort::text, 4, '0') || lpad(t.n::text, 8, '0')
    )::uuid,
    c.id,
    t.title,
    t.category,
    true,
    false,
    1
  from public.children c
  cross join (
    values
      (1, 'T-shirts', 'Clothes'),
      (2, 'Underwear', 'Clothes'),
      (3, 'Socks', 'Clothes'),
      (4, 'Pyjamas', 'Clothes'),
      (5, 'Warm coat', 'Warm'),
      (6, 'Light jumper', 'Warm'),
      (7, 'Gloves', 'Snow'),
      (8, 'Beanie', 'Snow'),
      (9, 'Thermals', 'Snow'),
      (10, 'Swimsuit', 'Sun'),
      (11, 'Sun hat', 'Sun'),
      (12, 'Sunscreen', 'Sun'),
      (13, 'Sandals', 'Sun'),
      (14, 'Toothbrush and toothpaste', 'Toiletries'),
      (15, 'Personal medication', 'Toiletries'),
      (16, 'Phone charger', 'Electronics'),
      (17, 'Refillable bottle', 'Bags'),
      (18, 'Passport, in a bag you carry', 'Documents')
  ) as t(n, title, category)
  on conflict (id) do nothing;
end
$fn$;

select private.seed_kids_content();

alter table public.children enable row level security;
alter table public.child_invites enable row level security;
alter table public.trip_itinerary enable row level security;
alter table public.climate_normals enable row level security;
alter table public.climate_gaps enable row level security;
alter table public.packing_items enable row level security;
alter table public.packing_ops enable row level security;

alter table public.children force row level security;
alter table public.child_invites force row level security;
alter table public.trip_itinerary force row level security;
alter table public.climate_normals force row level security;
alter table public.climate_gaps force row level security;
alter table public.packing_items force row level security;
alter table public.packing_ops force row level security;

revoke all on table public.children from public, anon, authenticated;
revoke all on table public.child_invites from public, anon, authenticated;
revoke all on table public.trip_itinerary from public, anon, authenticated;
revoke all on table public.climate_normals from public, anon, authenticated;
revoke all on table public.climate_gaps from public, anon, authenticated;
revoke all on table public.packing_items from public, anon, authenticated;
revoke all on table public.packing_ops from public, anon, authenticated;

grant select on table public.children to authenticated;
grant select, insert, update, delete on table public.trip_itinerary to authenticated;
grant select on table public.climate_normals to authenticated;
grant select on table public.climate_gaps to authenticated;
grant select on table public.packing_items to authenticated;

drop policy if exists children_select on public.children;
create policy children_select on public.children
  for select to authenticated
  using (public.is_trip_member() or public.is_child_self(id));

drop policy if exists itinerary_select on public.trip_itinerary;
create policy itinerary_select on public.trip_itinerary
  for select to authenticated
  using (
    public.is_trip_member()
    or coalesce(auth.jwt() -> 'app_metadata' ->> 'trip_role', '') = 'child'
  );

drop policy if exists itinerary_write on public.trip_itinerary;
create policy itinerary_write on public.trip_itinerary
  for all to authenticated
  using (public.is_trip_member())
  with check (public.is_trip_member());

drop policy if exists climate_select on public.climate_normals;
create policy climate_select on public.climate_normals
  for select to authenticated
  using (
    public.is_trip_member()
    or coalesce(auth.jwt() -> 'app_metadata' ->> 'trip_role', '') = 'child'
  );

drop policy if exists climate_gaps_select on public.climate_gaps;
create policy climate_gaps_select on public.climate_gaps
  for select to authenticated
  using (
    public.is_trip_member()
    or coalesce(auth.jwt() -> 'app_metadata' ->> 'trip_role', '') = 'child'
  );

drop policy if exists packing_select on public.packing_items;
create policy packing_select on public.packing_items
  for select to authenticated
  using (public.is_trip_member() or public.is_child_self(child_id));

revoke all on function public.apply_packing_op(uuid, uuid, uuid, integer, text, integer, text, boolean, boolean, boolean) from public, anon, authenticated;
grant execute on function public.apply_packing_op(uuid, uuid, uuid, integer, text, integer, text, boolean, boolean, boolean) to authenticated;

revoke all on function public.claim_child_invite(text, text) from public, anon, authenticated;
grant execute on function public.claim_child_invite(text, text) to anon, authenticated;

revoke all on function public.create_child_invite(text) from public, anon, authenticated;
grant execute on function public.create_child_invite(text) to authenticated;

revoke all on function public.my_access() from public, anon, authenticated;
grant execute on function public.my_access() to authenticated;

revoke all on function public.is_child_self(uuid) from public, anon, authenticated;
grant execute on function public.is_child_self(uuid) to authenticated;

revoke all on function private.apply_packing_op(uuid, uuid, uuid, integer, text, integer, text, boolean, boolean, boolean) from public, anon, authenticated;
grant execute on function private.apply_packing_op(uuid, uuid, uuid, integer, text, integer, text, boolean, boolean, boolean) to authenticated;

revoke all on function private.claim_child_invite(text, text) from public, anon, authenticated;
grant execute on function private.claim_child_invite(text, text) to anon, authenticated;

revoke all on function private.create_child_invite(text) from public, anon, authenticated;
grant execute on function private.create_child_invite(text) to authenticated;

revoke all on function private.packing_json(public.packing_items) from public, anon, authenticated;
revoke all on function private.seed_kids_content() from public, anon, authenticated;

do $pub$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'packing_items'
    ) then
      alter publication supabase_realtime add table public.packing_items;
    end if;
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'trip_itinerary'
    ) then
      alter publication supabase_realtime add table public.trip_itinerary;
    end if;
  end if;
end
$pub$;

commit;
