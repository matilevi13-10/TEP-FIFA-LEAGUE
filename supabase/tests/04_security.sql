\set ON_ERROR_STOP on
\pset pager off

\echo '=== 23. non-admins cannot reach admin functions ==='
do $$ begin
  perform act_as_team('Route One');
  begin
    perform admin_create_placeholder('Sneaky');
    raise exception 'TEST FAILED: non-admin created a placeholder';
  exception when sqlstate 'P0001' then raise notice 'ok: admin_create_placeholder blocked'; end;
  begin
    perform admin_start_playoffs(4);
    raise exception 'TEST FAILED: non-admin started playoffs';
  exception when sqlstate 'P0001' then raise notice 'ok: admin_start_playoffs blocked'; end;
  begin
    perform admin_delete_message((select id from messages limit 1));
    raise exception 'TEST FAILED: non-admin deleted a message';
  exception when sqlstate 'P0001' then raise notice 'ok: admin_delete_message blocked'; end;
  begin
    perform admin_dissolve_team((select id from teams limit 1));
    raise exception 'TEST FAILED: non-admin dissolved a team';
  exception when sqlstate 'P0001' then raise notice 'ok: admin_dissolve_team blocked'; end;
  begin
    perform admin_update_settings('Hijacked', 10, 5000, 8, 'attacker@example.com');
    raise exception 'TEST FAILED: non-admin changed league settings';
  exception when sqlstate 'P0001' then raise notice 'ok: admin_update_settings blocked'; end;
end $$;

\echo '=== 24. as the authenticated role: reads allowed, writes denied ==='
set role authenticated;
select set_config('test.uid', (select user_id::text from players where name='Tom'), false);

do $$ begin
  begin
    update players set email = 'attacker@example.com' where name = 'Tom';
    raise exception 'TEST FAILED: a player rewrote their own email';
  exception when insufficient_privilege then raise notice 'ok: email column not writable'; end;
end $$;

do $$ begin
  begin
    insert into matches (phase, team_a, team_b, score_a, score_b, status)
    values ('league', (select id from teams limit 1), (select id from teams offset 1 limit 1), 99, 0, 'confirmed');
    raise exception 'TEST FAILED: direct match insert succeeded';
  exception when insufficient_privilege then raise notice 'ok: direct match insert blocked'; end;
  begin
    update players set is_admin = true where name = 'Tom';
    raise exception 'TEST FAILED: player granted themselves admin';
  exception when insufficient_privilege then raise notice 'ok: direct players update blocked'; end;
  begin
    insert into messages (kind, body, author_name) values ('chat', 'spoofed', 'Someone Else');
    raise exception 'TEST FAILED: direct message insert succeeded';
  exception when insufficient_privilege then raise notice 'ok: direct message insert blocked'; end;
  begin
    update teams set name = 'Hijacked' where id = (select id from teams limit 1);
    raise exception 'TEST FAILED: direct teams update succeeded';
  exception when insufficient_privilege then raise notice 'ok: direct teams update blocked'; end;
end $$;

do $$ declare n int; begin
  select count(*) into n from teams;    raise notice 'ok: can read % teams', n;
  select count(*) into n from players;  raise notice 'ok: can read % players', n;
  select count(*) into n from messages; raise notice 'ok: can read % messages', n;
  select count(*) into n from standings; raise notice 'ok: can read standings (% rows)', n;
end $$;
reset role;

\echo '=== 25. team creation is validated server-side ==='
do $$ begin
  perform act_as('Tom');   -- Tom is on Route One
  begin
    perform create_team('Sneaky Second', null, 'Ghost');
    raise exception 'TEST FAILED: a teamed player created another team';
  exception when sqlstate 'P0001' then raise notice 'ok: one team per person enforced'; end;
end $$;

\echo '=== 27. admin dissolves a team; both players return to the pool ==='
do $$ declare t uuid; n int; begin
  perform act_as('Mati');
  perform admin_reset_playoffs();
  select id into t from teams where name='Long Ball FC';
  perform admin_dissolve_team(t);
  if exists (select 1 from teams where id = t) then
    raise exception 'TEST FAILED: team survived dissolution';
  end if;
  select count(*) into n from players where name in ('Kai','Ozzy') and team_id is null and slot is null;
  if n <> 2 then raise exception 'TEST FAILED: % of 2 players returned to the pool', n; end if;
  raise notice 'ok: dissolved team returned both players to the pool';

  -- and they can make a new team straight away
  perform act_as('Kai');
  perform create_team('Reformed', (select id from players where name='Ozzy'), null);
  if not exists (select 1 from teams where name='Reformed') then
    raise exception 'TEST FAILED: freed players could not re-form';
  end if;
  raise notice 'ok: freed players formed a new team';
end $$;

\echo '=== 28. moving the admin address moves the controls ==='
do $$ begin
  perform act_as('Mati');
  perform admin_update_settings('Season 1', 12, 5000, 8, 'nico@example.com');
  perform act_as('Nico');
  if not is_admin() then raise exception 'TEST FAILED: the new admin address has no controls'; end if;
  raise notice 'ok: admin follows the configured address';
  perform act_as('Mati');
  if is_admin() then raise exception 'TEST FAILED: the old admin kept the controls'; end if;
  raise notice 'ok: the previous admin lost them';
  -- hand it back
  perform act_as('Nico');
  perform admin_update_settings('Season 1', 12, 5000, 8, 'matilevi13@gmail.com');
end $$;
