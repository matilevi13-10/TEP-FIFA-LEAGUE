\set ON_ERROR_STOP on
\pset pager off

\echo '=== 15. a normal player cannot call admin functions ==='
do $$ begin
  perform act_as('Alpha');
  begin
    perform admin_create_team('Sneaky','A','B','9999');
    raise exception 'TEST FAILED: non-admin created a team';
  exception when sqlstate 'P0001' then raise notice 'ok: admin_create_team blocked'; end;
  begin
    perform admin_resolve_match((select id from matches limit 1), 9, 0);
    raise exception 'TEST FAILED: non-admin resolved a match';
  exception when sqlstate 'P0001' then raise notice 'ok: admin_resolve_match blocked'; end;
  begin
    perform admin_start_playoffs(4);
    raise exception 'TEST FAILED: non-admin started playoffs';
  exception when sqlstate 'P0001' then raise notice 'ok: admin_start_playoffs blocked'; end;
end $$;

\echo '=== 16. RLS: as the authenticated role, secrets are unreadable ==='
set role authenticated;
select set_config('test.uid', (select user_id::text from teams where name='Alpha'), false);
do $$ declare n int; begin
  select count(*) into n from team_secrets;
  if n <> 0 then raise exception 'TEST FAILED: read % PIN hash rows', n; end if;
  raise notice 'ok: team_secrets readable but empty (RLS deny-all)';
exception when insufficient_privilege then
  raise notice 'ok: team_secrets denied outright (no grant + RLS deny-all)';
end $$;
do $$ begin
  begin
    insert into matches (phase, team_a, team_b, score_a, score_b, status)
    values ('league', (select id from teams where name='Alpha'),
            (select id from teams where name='Bravo'), 99, 0, 'confirmed');
    raise exception 'TEST FAILED: direct match insert succeeded';
  exception when insufficient_privilege then raise notice 'ok: direct match insert blocked'; end;
end $$;
do $$ begin
  begin
    update teams set is_admin = true where name='Alpha';
    raise exception 'TEST FAILED: player granted themselves admin';
  exception when insufficient_privilege then raise notice 'ok: direct teams update blocked'; end;
end $$;
do $$ declare n int; begin
  select count(*) into n from teams;      -- reads are allowed
  raise notice 'ok: player can read % teams', n;
  select count(*) into n from standings;
  raise notice 'ok: player can read standings (% rows)', n;
end $$;
reset role;

\echo '=== 17. PIN lockout after repeated misses ==='
do $$ declare tid uuid; i int; begin
  select id into tid from teams where name='Golf';
  for i in 1..8 loop
    begin perform begin_signin(tid, '0000'); exception when sqlstate 'P0001' then null; end;
  end loop;
  begin
    perform begin_signin(tid, '7777');    -- correct PIN, but locked out
    raise exception 'TEST FAILED: lockout did not engage';
  exception when sqlstate 'P0001' then raise notice 'ok: locked out after 8 misses'; end;
end $$;
update team_secrets set failed_count=0, locked_until=null;   -- release for later tests

\echo '=== 18. dispute, then admin resolves it ==='
select admin_reset_playoffs() from (select act_as('Admin')) _;
do $$ declare b uuid; mid uuid; begin
  perform act_as('Alpha');
  select id into b from teams where name='Bravo';
  mid := submit_league_result(b, 5, 0);
  perform act_as('Bravo');
  perform dispute_match(mid);
  if (select status from matches where id=mid) <> 'disputed' then
    raise exception 'TEST FAILED: dispute did not stick';
  end if;
  if (select played from standings where name='Alpha') <> 4 then
    raise exception 'TEST FAILED: a disputed match counted in the table';
  end if;
  raise notice 'ok: disputed match is parked, not counted';
  perform act_as('Admin');
  perform admin_resolve_match(mid, 2, 2, 'both agreed it was 2-2');
  if (select status from matches where id=mid) <> 'confirmed' then
    raise exception 'TEST FAILED: admin resolution did not confirm';
  end if;
  raise notice 'ok: admin resolved the dispute';
end $$;

\echo '=== 19. games-per-team cap is enforced ==='
do $$ declare b uuid; begin
  perform act_as('Admin');
  perform admin_update_settings('Season 1', 5, 5000, 8);
  perform act_as('Alpha');   -- Alpha has 5 played now
  select id into b from teams where name='Charlie';
  begin
    perform submit_league_result(b, 1, 0);
    raise exception 'TEST FAILED: submission accepted past the game limit';
  exception when sqlstate 'P0001' then raise notice 'ok: game cap enforced'; end;
  perform act_as('Admin');
  perform admin_update_settings('Season 1', 10, 5000, 8);
end $$;

\echo '=== 20. a submitter can take back their own pending result ==='
do $$ declare c uuid; mid uuid; before int; begin
  perform act_as('Alpha');
  select count(*) into before from matches where phase='league';
  select id into c from teams where name='Charlie';
  mid := submit_league_result(c, 3, 1);
  perform cancel_submission(mid);
  if (select count(*) from matches where phase='league') <> before then
    raise exception 'TEST FAILED: cancelled submission left a row behind';
  end if;
  raise notice 'ok: submission withdrawn';
end $$;

\echo '=== 21. 4-team and 16-team brackets build correctly ==='
do $$ begin perform act_as('Admin'); perform admin_start_playoffs(4); end $$;
select round, count(*) as slots from matches where phase='playoff' group by round order by round;
select slot, seed_a, seed_b from matches where phase='playoff' and round=1 order by slot;

do $$ begin
  perform act_as('Admin'); perform admin_reset_playoffs();
  begin
    perform admin_start_playoffs(16);
    raise exception 'TEST FAILED: 16-team bracket built from 8 teams';
  exception when sqlstate 'P0001' then raise notice 'ok: refuses a 16-bracket with only 8 teams'; end;
end $$;

\echo '=== 22. players are stored as rows, two per team ==='
do $$ declare tid uuid; n int; begin
  perform act_as('Admin');
  tid := admin_create_team('Test XI', 'Ana', 'Bruno', '4321');

  select count(*) into n from players where team_id = tid;
  if n <> 2 then raise exception 'TEST FAILED: expected 2 player rows, got %', n; end if;
  raise notice 'ok: create_team wrote 2 player rows';

  if (select name from players where team_id = tid and slot = 1) <> 'Ana'
     or (select name from players where team_id = tid and slot = 2) <> 'Bruno' then
    raise exception 'TEST FAILED: player slots wrong';
  end if;
  raise notice 'ok: slots 1 and 2 hold the right names';

  -- a third player, or a duplicate slot, must be impossible
  begin
    insert into players (team_id, name, slot) values (tid, 'Carla', 1);
    raise exception 'TEST FAILED: duplicate slot accepted';
  exception when unique_violation then raise notice 'ok: one player per slot enforced'; end;
  begin
    insert into players (team_id, name, slot) values (tid, 'Carla', 3);
    raise exception 'TEST FAILED: a third player was accepted';
  exception when check_violation then raise notice 'ok: only two slots exist'; end;

  -- the sign-in picker still reads both names
  if (select player_one || '/' || player_two from list_teams_for_signin() where id = tid) <> 'Ana/Bruno' then
    raise exception 'TEST FAILED: sign-in list lost the player names';
  end if;
  raise notice 'ok: sign-in list joins both names';

  -- renaming through the admin RPC updates in place, does not duplicate
  perform admin_update_team(tid, 'Test XI', 'Ana', 'Caio', true, true);
  select count(*) into n from players where team_id = tid;
  if n <> 2 or (select name from players where team_id = tid and slot = 2) <> 'Caio' then
    raise exception 'TEST FAILED: update_team did not upsert cleanly (% rows)', n;
  end if;
  raise notice 'ok: update_team renames in place';

  -- deleting the team takes its players with it
  perform admin_delete_team(tid);
  select count(*) into n from players where team_id = tid;
  if n <> 0 then raise exception 'TEST FAILED: % orphaned player rows', n; end if;
  raise notice 'ok: players cascade on team delete';
end $$;
