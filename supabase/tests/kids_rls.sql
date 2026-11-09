-- Permission checks against the migrated schema. Run as a superuser on a throwaway database.
-- Uses SET ROLE so row level security actually applies (a superuser would bypass it).
\set ON_ERROR_STOP on

do $t$
declare
  v_code jsonb;
  v_claim jsonb;
  v_uid uuid;
  v_n int;
  v_title text;
  v_status text;
  v_version int;
  v_op uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1';
  v_op2 uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2';
  v_item uuid := 'b0000001-0000-4000-8000-000100000001';
  v_res jsonb;
begin
  -- Public sign-up stays closed.
  begin
    insert into auth.users (id, email, raw_app_meta_data)
    values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'someone@example.com', '{}'::jsonb);
    raise exception 'random signup was allowed';
  exception when others then
    if sqlerrm <> 'Sign-ups are closed' then
      raise;
    end if;
  end;

  perform set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","role":"authenticated","email":"adamkiil79@gmail.com","app_metadata":{}}', true);
  execute 'set local role authenticated';
  v_code := public.create_child_invite('liam');
  if coalesce(v_code ->> 'code', '') = '' then
    raise exception 'invite did not return a code';
  end if;
  if v_code ->> 'email' <> 'liam@kids.usa-trip.invalid' then
    raise exception 'unexpected invite email';
  end if;
  execute 'reset role';

  execute 'set local role anon';
  begin
    perform public.create_child_invite('ana');
    raise exception 'anon created an invite';
  exception when insufficient_privilege or sqlstate '42501' then
    null;
  end;
  v_claim := public.claim_child_invite(v_code ->> 'code', 'test-password-1');
  if v_claim ->> 'email' <> 'liam@kids.usa-trip.invalid' then
    raise exception 'claim failed';
  end if;
  v_claim := public.claim_child_invite(v_code ->> 'code', 'test-password-1');
  if v_claim ->> 'error' is distinct from 'That code has already been used' then
    raise exception 'invite code was reused: %', v_claim;
  end if;
  execute 'reset role';

  if (select encrypted_password from auth.users where email = 'liam@kids.usa-trip.invalid') = 'test-password-1'
     or (select encrypted_password from auth.users where email = 'liam@kids.usa-trip.invalid') not like '$2%' then
    raise exception 'password was not stored as bcrypt';
  end if;
  if exists (
    select 1 from auth.users
    where email = 'liam@kids.usa-trip.invalid'
      and (encrypted_password = 'test-password-1' or raw_app_meta_data::text like '%test-password-1%' or raw_user_meta_data::text like '%test-password-1%')
  ) then
    raise exception 'plaintext password landed in auth.users';
  end if;

  select id into v_uid from auth.users where email = 'liam@kids.usa-trip.invalid';
  if v_uid is null then
    raise exception 'child user missing';
  end if;
  if (select raw_app_meta_data ->> 'trip_role' from auth.users where id = v_uid) <> 'child' then
    raise exception 'child role was not stored in app_metadata';
  end if;

  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_uid,
    'role', 'authenticated',
    'email', 'liam@kids.usa-trip.invalid',
    'app_metadata', json_build_object(
      'trip_role', 'child',
      'child_id', 'c0a1d000-0000-4000-8000-000000000001',
      'child_slug', 'liam'
    )
  )::text, true);
  execute 'set local role authenticated';

  if (public.my_access() ->> 'role') <> 'child' or (public.my_access() ->> 'display_name') <> 'Liam' then
    raise exception 'my_access did not return Liam';
  end if;

  select count(*) into v_n from public.items;
  if v_n <> 0 then
    raise exception 'child can read parent items';
  end if;
  select count(*) into v_n from public.suggestions;
  if v_n <> 0 then
    raise exception 'child can read suggestions';
  end if;

  update public.items set title = 'changed' where id = 't-row';
  execute 'reset role';
  select title into v_title from public.items where id = 't-row';
  if v_title <> 'parent-only' then
    raise exception 'child update changed a parent item';
  end if;

  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_uid, 'role', 'authenticated', 'email', 'liam@kids.usa-trip.invalid',
    'app_metadata', json_build_object('trip_role', 'child', 'child_id', 'c0a1d000-0000-4000-8000-000000000001')
  )::text, true);
  execute 'set local role authenticated';

  select count(*) into v_n from public.packing_items;
  if v_n <> 18 then
    raise exception 'child should see only their 18 packing rows, saw %', v_n;
  end if;
  select count(*) into v_n from public.packing_items where child_id = 'c0a1d000-0000-4000-8000-000000000002';
  if v_n <> 0 then
    raise exception 'child can read a sibling list';
  end if;
  select count(*) into v_n from public.trip_itinerary;
  if v_n <> 18 then
    raise exception 'child cannot read the itinerary';
  end if;
  select count(*) into v_n from public.climate_normals;
  if v_n < 8 then
    raise exception 'child cannot read climate normals';
  end if;
  if not exists (select 1 from public.climate_gaps where place_key = 'cococay') then
    raise exception 'child cannot read climate gaps';
  end if;

  begin
    insert into public.trip_itinerary (id, starts_on, title, sort)
    values ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', '2026-12-10', 'secret day', 999);
    raise exception 'child inserted an itinerary row';
  exception when insufficient_privilege or sqlstate '42501' then
    null;
  end;

  begin
    perform public.apply_packing_op(
      'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb9',
      'b0000001-0000-4000-8000-000200000001',
      'c0a1d000-0000-4000-8000-000000000002',
      1, 'Stolen', null, 'Clothes', false, false, true
    );
    raise exception 'child edited a sibling row';
  exception when sqlstate '42501' then
    null;
  end;

  begin
    perform public.apply_packing_op(
      'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbba',
      'b0000001-0000-4000-8000-000100000002',
      '99999999-9999-4999-8999-999999999999',
      null, 'Forged', null, 'Clothes', false, false, false
    );
    raise exception 'forged child id was accepted';
  exception when sqlstate '42501' then
    null;
  end;

  begin
    perform public.create_child_invite('ana');
    raise exception 'child minted an invite';
  exception when sqlstate '42501' then
    null;
  end;

  begin
    update auth.users set raw_app_meta_data = '{"trip_role":"parent"}'::jsonb where id = v_uid;
    raise exception 'child rewrote app_metadata';
  exception when insufficient_privilege then
    null;
  end;
  if (public.my_access() ->> 'role') = 'parent' then
    raise exception 'child my_access returned parent';
  end if;

  v_res := public.apply_packing_op(v_op, v_item, 'c0a1d000-0000-4000-8000-000000000001', 1, 'T-shirts', 4, 'Clothes', true, false, true);
  if v_res ->> 'status' <> 'applied' or (v_res -> 'item' ->> 'version')::int <> 2 then
    raise exception 'first packing op failed: %', v_res;
  end if;
  v_res := public.apply_packing_op(v_op, v_item, 'c0a1d000-0000-4000-8000-000000000001', 1, 'T-shirts', 9, 'Clothes', false, false, true);
  if v_res ->> 'status' <> 'duplicate' or (v_res -> 'item' ->> 'qty')::int <> 4 or (v_res -> 'item' ->> 'version')::int <> 2 then
    raise exception 'duplicate op was not idempotent: %', v_res;
  end if;
  v_res := public.apply_packing_op(v_op2, v_item, 'c0a1d000-0000-4000-8000-000000000001', 1, 'Old title', null, 'Clothes', false, false, true);
  if v_res ->> 'status' <> 'conflict' or (v_res -> 'item' ->> 'title') <> 'T-shirts' or (v_res -> 'item' ->> 'qty')::int <> 4 then
    raise exception 'stale op overwrote a newer row: %', v_res;
  end if;
  execute 'reset role';

  select version, title, qty into v_version, v_title, v_n from public.packing_items where id = v_item;
  if v_version <> 2 or v_title <> 'T-shirts' or v_n <> 4 then
    raise exception 'server row changed after the conflict';
  end if;

  update public.packing_items set checked = true where id = v_item;
  update public.trip_itinerary set title = 'Edited day' where id = 'a1000000-0000-4000-8000-000000000001';
  perform private.seed_kids_content();
  if (select checked from public.packing_items where id = v_item) is not true then
    raise exception 're-seed cleared a packing tick';
  end if;
  if (select title from public.trip_itinerary where id = 'a1000000-0000-4000-8000-000000000001') <> 'Edited day' then
    raise exception 're-seed overwrote an itinerary edit';
  end if;
  if (select high_c from public.climate_normals where place_key = 'nyc' and month = 12) <> 7 then
    raise exception 'climate normal missing';
  end if;

  perform set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","role":"authenticated","email":"adamkiil79@gmail.com","app_metadata":{}}', true);
  execute 'set local role authenticated';
  select count(*) into v_n from public.items;
  if v_n <> 1 then
    raise exception 'parent lost access to items';
  end if;
  select count(*) into v_n from public.packing_items;
  if v_n < 70 then
    raise exception 'parent cannot see every child list';
  end if;
  if (public.my_access() ->> 'role') <> 'parent' then
    raise exception 'parent access lookup failed';
  end if;
  execute 'reset role';

  execute 'set local role anon';
  begin
    perform count(*) from public.packing_items;
    raise exception 'anon read packing';
  exception when insufficient_privilege then
    null;
  end;
  begin
    perform count(*) from public.trip_itinerary;
    raise exception 'anon read itinerary';
  exception when insufficient_privilege then
    null;
  end;
  begin
    perform count(*) from public.items;
    raise exception 'anon read items';
  exception when insufficient_privilege then
    null;
  end;
  execute 'reset role';

  select has_table_privilege('anon', 'public.packing_items', 'select') into v_status;
  if v_status::boolean then
    raise exception 'anon still has select on packing';
  end if;

  perform set_config('trip.allow_child_signup', 'on', true);
  begin
    insert into auth.users (id, email, raw_app_meta_data)
    values ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'stranger@example.com', '{"trip_role":"child"}'::jsonb);
    raise exception 'signup flag allowed a stranger';
  exception when others then
    if sqlerrm <> 'Sign-ups are closed' then
      raise;
    end if;
  end;
  begin
    insert into auth.users (id, email, raw_app_meta_data)
    values ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', 'ana@kids.usa-trip.invalid', '{"trip_role":"parent"}'::jsonb);
    raise exception 'child address was accepted as a parent';
  exception when others then
    if sqlerrm <> 'Sign-ups are closed' then
      raise;
    end if;
  end;

  execute 'set local role anon';
  perform set_config('trip.allow_child_signup', 'on', true);
  begin
    insert into auth.users (id, email, raw_app_meta_data)
    values ('ffffffff-ffff-4fff-8fff-ffffffffffff', 'ana@kids.usa-trip.invalid', '{"trip_role":"child"}'::jsonb);
    raise exception 'anon inserted a child user directly';
  exception when insufficient_privilege then
    null;
  end;
  execute 'reset role';
  delete from private.claim_attempts;
  execute 'set local role anon';
  for v_n in 1..30 loop
    v_claim := public.claim_child_invite('not-a-real-code-value', 'longpassword');
    if v_claim ->> 'error' is distinct from 'That code is not valid' then
      raise exception 'unexpected failure while filling the attempt limit: %', v_claim;
    end if;
  end loop;
  v_claim := public.claim_child_invite('not-a-real-code-value', 'longpassword');
  if v_claim ->> 'error' is distinct from 'Too many attempts. Wait a few minutes and try again.' then
    raise exception 'rate limit did not trip: %', v_claim;
  end if;
  begin
    perform count(*) from private.claim_attempts;
    raise exception 'anon read claim attempts';
  exception when insufficient_privilege then
    null;
  end;
  execute 'reset role';
end
$t$;
