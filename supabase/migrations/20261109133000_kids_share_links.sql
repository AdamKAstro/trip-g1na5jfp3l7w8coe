-- Shareable child links. Additive. Depends on 20261109010000_kids_area.sql.
-- Coordinator: run this whole file once. Do not put a service-role key in the website.
--
-- Does not replace is_trip_member(), items_stamp(), suggestions_guard(), or the
-- existing permissive items/suggestions policies. Adds a restrictive session check
-- so a cancelled link's access token stops reading child data. Parents are unchanged:
-- the check is true unless app_metadata.trip_role is child.
--
-- The link token is the child's password. It is returned once to the parent and stored
-- only as a SHA-256 hash. Cancelling or replacing a link sets a new unknown password
-- and deletes that child's auth sessions and refresh tokens.

begin;

do $guard$
begin
  if to_regclass('public.children') is null or to_regprocedure('private.claim_limited(text)') is null then
    raise exception 'kids area migration is missing; refusing to continue';
  end if;
  if to_regclass('auth.sessions') is null or to_regclass('auth.refresh_tokens') is null then
    raise exception 'auth sessions are missing; refusing to continue';
  end if;
end
$guard$;

create table if not exists public.child_links (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children (id),
  token_hash text not null unique,
  created_at timestamptz not null default pg_catalog.now(),
  revoked_at timestamptz,
  created_by uuid
);

create unique index if not exists child_links_one_active
  on public.child_links (child_id)
  where revoked_at is null;

alter table public.child_links enable row level security;
alter table public.child_links force row level security;
revoke all on table public.child_links from public, anon, authenticated;

create or replace function private.child_session_ok()
returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'trip_role', '') is distinct from 'child'
    or (
      coalesce(auth.jwt() ->> 'session_id', '') ~* '^[0-9a-f-]{36}$'
      and exists (
        select 1 from auth.sessions s
        where s.id = (auth.jwt() ->> 'session_id')::uuid
          and s.user_id = auth.uid()
      )
    )
$fn$;

revoke all on function private.child_session_ok() from public, anon, authenticated;
grant execute on function private.child_session_ok() to authenticated;

create or replace function private.sign_out_child(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  delete from auth.refresh_tokens
  where user_id = p_user::text
     or session_id in (select id from auth.sessions where user_id = p_user);
  delete from auth.sessions where user_id = p_user;
end
$fn$;

revoke all on function private.sign_out_child(uuid) from public, anon, authenticated;

create or replace function private.ensure_child_user(p_child_id uuid, p_password text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_child public.children%rowtype;
  v_user auth.users%rowtype;
  v_meta jsonb;
begin
  if p_password is null or char_length(p_password) < 8 or char_length(p_password) > 72 then
    raise exception 'bad link' using errcode = '22023';
  end if;
  select * into v_child from public.children where id = p_child_id;
  if not found then
    raise exception 'Unknown child' using errcode = '22023';
  end if;
  v_meta := pg_catalog.jsonb_build_object(
    'provider', 'email',
    'providers', pg_catalog.jsonb_build_array('email'),
    'trip_role', 'child',
    'child_id', v_child.id::text,
    'child_slug', v_child.slug
  );
  select * into v_user from auth.users where lower(email) = lower(v_child.email);
  if found then
    if coalesce(v_user.raw_app_meta_data ->> 'trip_role', '') is distinct from 'child' then
      raise exception 'Sign-ups are closed' using errcode = '42501';
    end if;
    update auth.users set
      encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
      raw_app_meta_data = v_meta,
      email_confirmed_at = coalesce(email_confirmed_at, pg_catalog.now()),
      updated_at = pg_catalog.now()
    where id = v_user.id;
    return v_user.id;
  end if;
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
  update public.children set user_id = v_user.id where id = v_child.id and user_id is null;
  return v_user.id;
end
$fn$;

revoke all on function private.ensure_child_user(uuid, text) from public, anon, authenticated;

create or replace function private.issue_child_link(p_slug text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_child public.children%rowtype;
  v_token text;
  v_hash text;
  v_user uuid;
  v_at timestamptz;
  v_id uuid;
begin
  if not public.is_trip_member() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into v_child from public.children where slug = p_slug;
  if not found then
    raise exception 'Unknown child' using errcode = '22023';
  end if;
  v_token := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
  v_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');
  v_user := private.ensure_child_user(v_child.id, v_token);
  update public.child_links set revoked_at = pg_catalog.now()
  where child_id = v_child.id and revoked_at is null;
  perform private.sign_out_child(v_user);
  v_at := pg_catalog.now();
  insert into public.child_links (child_id, token_hash, created_at, created_by)
  values (v_child.id, v_hash, v_at, auth.uid())
  returning id into v_id;
  return pg_catalog.jsonb_build_object(
    'id', v_id,
    'token', v_token,
    'email', v_child.email,
    'display_name', v_child.display_name,
    'created_at', v_at
  );
end
$fn$;

create or replace function public.issue_child_link(p_slug text)
returns jsonb
language sql
security invoker
set search_path = ''
as $fn$
  select private.issue_child_link(p_slug)
$fn$;

create or replace function private.child_link_status()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select case
    when public.is_trip_member() then coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'slug', c.slug,
        'id', l.id,
        'active', l.id is not null,
        'created_at', l.created_at
      ) order by c.sort)
      from public.children c
      left join public.child_links l on l.child_id = c.id and l.revoked_at is null
    ), '[]'::jsonb)
    else '[]'::jsonb
  end
$fn$;

create or replace function public.child_link_status()
returns jsonb
language sql
security invoker
set search_path = ''
as $fn$
  select private.child_link_status()
$fn$;

create or replace function private.redeem_child_link(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_hash text;
  v_link public.child_links%rowtype;
  v_child public.children%rowtype;
begin
  if p_token is null or char_length(p_token) < 43 or char_length(p_token) > 128
     or p_token !~ '^[A-Za-z0-9_-]+$' then
    return private.claim_limited('This link doesn''t work any more. Ask Mum or Dad to share a new one.');
  end if;
  v_hash := encode(extensions.digest(p_token, 'sha256'), 'hex');
  select * into v_link from public.child_links
  where token_hash = v_hash and revoked_at is null;
  if not found then
    return private.claim_limited('This link doesn''t work any more. Ask Mum or Dad to share a new one.');
  end if;
  select * into v_child from public.children where id = v_link.child_id;
  if not found then
    return private.claim_limited('This link doesn''t work any more. Ask Mum or Dad to share a new one.');
  end if;
  return pg_catalog.jsonb_build_object('email', v_child.email, 'display_name', v_child.display_name);
end
$fn$;

create or replace function public.redeem_child_link(p_token text)
returns jsonb
language sql
security invoker
set search_path = ''
as $fn$
  select private.redeem_child_link(p_token)
$fn$;

drop policy if exists items_child_session on public.items;
create policy items_child_session on public.items
  as restrictive for all to authenticated
  using (private.child_session_ok())
  with check (private.child_session_ok());

drop policy if exists suggestions_child_session on public.suggestions;
create policy suggestions_child_session on public.suggestions
  as restrictive for all to authenticated
  using (private.child_session_ok())
  with check (private.child_session_ok());

drop policy if exists packing_child_session on public.packing_items;
create policy packing_child_session on public.packing_items
  as restrictive for all to authenticated
  using (private.child_session_ok())
  with check (private.child_session_ok());

drop policy if exists itinerary_child_session on public.trip_itinerary;
create policy itinerary_child_session on public.trip_itinerary
  as restrictive for all to authenticated
  using (private.child_session_ok())
  with check (private.child_session_ok());

drop policy if exists climate_child_session on public.climate_normals;
create policy climate_child_session on public.climate_normals
  as restrictive for select to authenticated
  using (private.child_session_ok());

drop policy if exists climate_gaps_child_session on public.climate_gaps;
create policy climate_gaps_child_session on public.climate_gaps
  as restrictive for select to authenticated
  using (private.child_session_ok());

drop policy if exists children_child_session on public.children;
create policy children_child_session on public.children
  as restrictive for select to authenticated
  using (private.child_session_ok());

revoke all on function public.issue_child_link(text) from public, anon, authenticated;
grant execute on function public.issue_child_link(text) to authenticated;
revoke all on function private.issue_child_link(text) from public, anon, authenticated;
grant execute on function private.issue_child_link(text) to authenticated;

revoke all on function public.child_link_status() from public, anon, authenticated;
grant execute on function public.child_link_status() to authenticated;
revoke all on function private.child_link_status() from public, anon, authenticated;
grant execute on function private.child_link_status() to authenticated;

revoke all on function public.redeem_child_link(text) from public, anon, authenticated;
grant execute on function public.redeem_child_link(text) to anon, authenticated;
revoke all on function private.redeem_child_link(text) from public, anon, authenticated;
grant execute on function private.redeem_child_link(text) to anon, authenticated;

commit;
