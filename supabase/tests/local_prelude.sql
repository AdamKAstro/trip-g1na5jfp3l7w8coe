-- Local stand-in for the hosted Supabase auth helpers. Not applied to production.
create schema if not exists auth;
create schema if not exists extensions;

create extension if not exists pgcrypto with schema extensions;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end $$;

grant usage on schema auth, extensions, public to anon, authenticated;

create table if not exists auth.users (
  instance_id uuid,
  id uuid primary key default gen_random_uuid(),
  aud varchar,
  role varchar,
  email varchar unique,
  encrypted_password varchar,
  email_confirmed_at timestamptz,
  raw_app_meta_data jsonb,
  raw_user_meta_data jsonb,
  created_at timestamptz,
  updated_at timestamptz,
  confirmation_token varchar,
  recovery_token varchar,
  email_change_token_new varchar,
  email_change varchar,
  email_change_token_current varchar,
  phone_change text,
  phone_change_token varchar,
  reauthentication_token varchar,
  is_sso_user boolean not null default false,
  is_anonymous boolean not null default false
);

create table if not exists auth.identities (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  identity_data jsonb not null,
  provider text not null,
  provider_id text not null,
  email text,
  created_at timestamptz,
  updated_at timestamptz,
  unique (provider, provider_id)
);

create or replace function auth.jwt()
returns jsonb
language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true), '')::jsonb
$$;

create or replace function auth.uid()
returns uuid
language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;

create or replace function auth.email()
returns text
language sql stable as $$
  select nullif(auth.jwt() ->> 'email', '')
$$;

create or replace function public.is_trip_member()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(lower(auth.jwt() ->> 'email') in ('adamkiil79@gmail.com', 'edware02@hotmail.com'), false)
$$;

create table if not exists public.items (
  id text primary key,
  title text,
  booking_refs text,
  done boolean not null default false
);
create table if not exists public.suggestions (
  id uuid primary key default gen_random_uuid(),
  body text
);

alter table public.items enable row level security;
alter table public.suggestions enable row level security;

drop policy if exists items_select on public.items;
create policy items_select on public.items for select to authenticated using (public.is_trip_member());
drop policy if exists items_update on public.items;
create policy items_update on public.items for update to authenticated using (public.is_trip_member()) with check (public.is_trip_member());
drop policy if exists suggestions_select on public.suggestions;
create policy suggestions_select on public.suggestions for select to authenticated using (public.is_trip_member());

grant select, update on public.items to authenticated;
grant select on public.suggestions to authenticated;

create or replace function public.block_other_signups()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if lower(coalesce(new.email, '')) not in ('adamkiil79@gmail.com', 'edware02@hotmail.com') then
    raise exception 'Sign-ups are closed';
  end if;
  return new;
end
$$;

drop trigger if exists block_other_signups on auth.users;
create trigger block_other_signups before insert on auth.users
  for each row execute function public.block_other_signups();

insert into public.items (id, title, booking_refs) values ('t-row', 'parent-only', 'HIDDEN')
on conflict (id) do nothing;
insert into public.suggestions (id, body) values ('11111111-1111-4111-8111-111111111111', 'parent note')
on conflict (id) do nothing;
