-- Share-link checks. Throwaway database only, after both kids migrations.
\set ON_ERROR_STOP on

do $t$
declare
  v_link jsonb;
  v_again jsonb;
  v_old text;
  v_new text;
  v_email text;
  v_uid uuid;
  v_sid uuid := 'abababab-abab-4aba-8aba-abababababab';
  v_sid2 uuid := 'cdcdcdcd-cdcd-4cdc-8cdc-cdcdcdcdcdcd';
  v_n int;
  v_hash text;
begin
  perform set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","role":"authenticated","email":"adamkiil79@gmail.com","app_metadata":{}}', true);
  execute 'set local role authenticated';
  v_link := public.issue_child_link('liam');
  v_old := v_link ->> 'token';
  if v_old is null or char_length(v_old) < 43 or position('?' in coalesce(v_link::text, '')) > 0 then
    raise exception 'link was not a long token';
  end if;
  if v_link ->> 'email' <> 'liam@kids.usa-trip.invalid' then
    raise exception 'link email mismatch';
  end if;
  execute 'reset role';

  v_hash := encode(extensions.digest(v_old, 'sha256'), 'hex');
  if exists (select 1 from public.child_links where token_hash = v_old) then
    raise exception 'plaintext token stored';
  end if;
  if not exists (select 1 from public.child_links where token_hash = v_hash and revoked_at is null) then
    raise exception 'token hash missing';
  end if;
  select id into v_uid from auth.users where email = 'liam@kids.usa-trip.invalid';
  if (select encrypted_password from auth.users where id = v_uid) = v_old
     or (select raw_app_meta_data::text || raw_user_meta_data::text from auth.users where id = v_uid) like '%' || v_old || '%' then
    raise exception 'token stored outside the password hash';
  end if;
  if (select extensions.crypt(v_old, encrypted_password) = encrypted_password from auth.users where id = v_uid) is not true then
    raise exception 'token is not the bcrypt password';
  end if;
  if (select raw_app_meta_data ->> 'trip_role' from auth.users where id = v_uid) <> 'child' then
    raise exception 'link user is not a child';
  end if;

  execute 'set local role anon';
  v_again := public.redeem_child_link(v_old);
  if v_again ->> 'email' <> 'liam@kids.usa-trip.invalid' or v_again ? 'token' then
    raise exception 'redeem did not return only the child email';
  end if;
  v_again := public.redeem_child_link('not-a-real-token-not-a-real-token-not-real');
  if v_again ->> 'email' is not null or v_again ->> 'error' is null then
    raise exception 'bad token was accepted';
  end if;
  begin
    perform public.issue_child_link('liam');
    raise exception 'anon minted a link';
  exception when insufficient_privilege then
    null;
  end;
  execute 'reset role';

  insert into auth.sessions (id, user_id) values (v_sid, v_uid);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_uid, 'role', 'authenticated', 'email', 'liam@kids.usa-trip.invalid', 'session_id', v_sid,
    'app_metadata', json_build_object('trip_role', 'child', 'child_id', 'c0a1d000-0000-4000-8000-000000000001')
  )::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from public.packing_items;
  if v_n <> 18 then
    raise exception 'live child session could not read own packing';
  end if;
  select count(*) into v_n from public.items;
  if v_n <> 0 then
    raise exception 'child link session can read parent items';
  end if;
  begin
    perform public.issue_child_link('ana');
    raise exception 'child minted a link';
  exception when sqlstate '42501' then
    null;
  end;
  execute 'reset role';

  perform set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","role":"authenticated","email":"adamkiil79@gmail.com","app_metadata":{}}', true);
  execute 'set local role authenticated';
  v_again := public.issue_child_link('liam');
  v_new := v_again ->> 'token';
  execute 'reset role';
  if v_new = v_old then
    raise exception 'rotated link reused the token';
  end if;
  if exists (select 1 from public.child_links where token_hash = v_hash and revoked_at is null) then
    raise exception 'old link still active';
  end if;
  if exists (select 1 from auth.sessions where id = v_sid) then
    raise exception 'old session was not signed out';
  end if;
  if (select extensions.crypt(v_old, encrypted_password) = encrypted_password from auth.users where id = v_uid) then
    raise exception 'cancelled token still matches the password';
  end if;
  if (select extensions.crypt(v_new, encrypted_password) = encrypted_password from auth.users where id = v_uid) is not true then
    raise exception 'new token is not the password';
  end if;

  execute 'set local role anon';
  v_again := public.redeem_child_link(v_old);
  if v_again ->> 'email' is not null then
    raise exception 'cancelled link still redeems';
  end if;
  v_again := public.redeem_child_link(v_new);
  if v_again ->> 'email' <> 'liam@kids.usa-trip.invalid' then
    raise exception 'new link does not redeem';
  end if;
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_uid, 'role', 'authenticated', 'email', 'liam@kids.usa-trip.invalid', 'session_id', v_sid,
    'app_metadata', json_build_object('trip_role', 'child', 'child_id', 'c0a1d000-0000-4000-8000-000000000001')
  )::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from public.packing_items;
  if v_n <> 0 then
    raise exception 'signed-out child session can still read packing';
  end if;
  execute 'reset role';

  insert into auth.sessions (id, user_id) values (v_sid2, v_uid);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_uid, 'role', 'authenticated', 'email', 'liam@kids.usa-trip.invalid', 'session_id', v_sid2,
    'app_metadata', json_build_object('trip_role', 'child', 'child_id', 'c0a1d000-0000-4000-8000-000000000001')
  )::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from public.packing_items;
  if v_n <> 18 then
    raise exception 'new session could not read own packing';
  end if;
  select count(*) into v_n from public.trip_itinerary;
  if v_n <> 18 then
    raise exception 'new session could not read the itinerary';
  end if;
  execute 'reset role';

  select email into v_email from auth.users where id = v_uid;
  if v_email <> 'liam@kids.usa-trip.invalid' then
    raise exception 'child email changed';
  end if;
end
$t$;
