\set ON_ERROR_STOP on
\pset pager off

-- Plays one playoff game: team_a's slot-1 player enters it from team_a's side,
-- team_b confirms.
create or replace function play_game(mid uuid, sa int, sb int, pens uuid default null) returns void
language plpgsql as $$
declare m matches%rowtype; begin
  select * into m from matches where id = mid;
  perform set_config('test.uid',
    (select user_id::text from players where team_id = m.team_a and slot = 1), false);
  perform submit_playoff_result(mid, sa, sb, pens);
  perform set_config('test.uid',
    (select user_id::text from players where team_id = m.team_b and slot = 1), false);
  perform confirm_match(mid);
end $$;

create or replace function leg(r int, s int, l int) returns uuid language sql as $$
  select id from matches where phase='playoff' and round=r and slot=s and leg=l;
$$;

-- Plays a whole tie so the better seed goes through: 2–1 away, 1–0 at home.
create or replace function play_tie(r int, s int) returns void
language plpgsql as $$
declare m matches%rowtype; better_is_a boolean; begin
  select * into m from matches where phase='playoff' and round=r and slot=s and leg=1;
  better_is_a := m.seed_a < m.seed_b;
  if public.playoff_is_final(r) then
    perform play_game(m.id, case when better_is_a then 1 else 0 end, case when better_is_a then 0 else 1 end);
  else
    perform play_game(leg(r, s, 1), case when better_is_a then 2 else 1 end, case when better_is_a then 1 else 2 end);
    perform play_game(leg(r, s, 2), case when better_is_a then 1 else 0 end, case when better_is_a then 0 else 1 end);
  end if;
end $$;

\echo '=== 16. seven teams: everyone qualifies, #1 gets the only bye ==='
do $$ declare t uuid; begin
  -- Take the league down to seven active teams, the size the rules are written for.
  perform act_as('Mati');
  for t in select team_id from standings order by rank desc limit 3 loop
    perform admin_update_team(t, (select name from teams where id = t), false,
                              (select paid from teams where id = t));
  end loop;
  perform admin_start_playoffs();
end $$;

select m.round, m.slot, m.leg, m.status, m.seed_a, ta.name as team_a, m.seed_b, tb.name as team_b,
       th.name as home
  from matches m left join teams ta on ta.id=m.team_a left join teams tb on tb.id=m.team_b
  left join teams th on th.id=m.home_team
 where m.phase='playoff' order by round, slot, leg;

do $$ declare top uuid; begin
  if (select playoff_size from league_settings) <> 7 then
    raise exception 'TEST FAILED: all 7 teams should be seeded';
  end if;
  if (select count(distinct t) from (
        select team_a t from matches where phase='playoff' and round=1
        union select team_b from matches where phase='playoff' and round=1) x
       where t is not null) <> 7 then
    raise exception 'TEST FAILED: not every team made the bracket';
  end if;
  raise notice 'ok: every team makes the playoffs';

  select team_id into top from standings where rank = 1;
  if (select count(*) from matches where phase='playoff' and status='bye') <> 1
     or (select team_a from matches where phase='playoff' and status='bye') <> top then
    raise exception 'TEST FAILED: the #1 seed should have the one bye';
  end if;
  if (select team_a from matches where phase='playoff' and round=2 and slot=0 and leg=1) <> top then
    raise exception 'TEST FAILED: the #1 seed did not go straight through to round 2';
  end if;
  raise notice 'ok: #1 seed has the only bye and is already in round 2';

  -- 1 bye + 3 two-leg ties, 2 two-leg semis, a one-game final.
  if (select count(*) from matches where phase='playoff') <> 1 + 6 + 4 + 1 then
    raise exception 'TEST FAILED: wrong number of playoff games';
  end if;
  if (select count(*) from matches where phase='playoff' and round=3) <> 1 then
    raise exception 'TEST FAILED: the final should be a single game';
  end if;
  raise notice 'ok: two-leg ties until a one-game final';

  -- The better seed hosts the second leg.
  if exists (select 1 from matches where phase='playoff' and round=1 and status<>'bye'
              and home_team <> case when (leg = 2) = (seed_a < seed_b) then team_a else team_b end) then
    raise exception 'TEST FAILED: home teams are the wrong way round';
  end if;
  raise notice 'ok: lower seed hosts leg 1, higher seed hosts leg 2';
end $$;

\echo '=== 17. the league locks, and teams cannot be dissolved mid-playoffs ==='
do $$ declare fix uuid; begin
  perform act_as_team('Los Galácticos');
  select id into fix from matches where phase='league' limit 1;
  begin
    perform submit_league_result(fix, 3, 0);
    raise exception 'TEST FAILED: league submission accepted after lock';
  exception when sqlstate 'P0001' then raise notice 'ok: league phase locked'; end;

  perform act_as('Mati');
  begin
    perform admin_dissolve_team((select id from teams where name='Tiki Taka'));
    raise exception 'TEST FAILED: team dissolved during playoffs';
  exception when sqlstate 'P0001' then raise notice 'ok: teams are frozen during playoffs'; end;
end $$;

\echo '=== 18. aggregate rules ==='
do $$ declare mid uuid; begin
  -- Round 1 slot 1 is 4 v 5.
  begin
    perform play_game(leg(1, 1, 2), 1, 0);
    raise exception 'TEST FAILED: second leg played before the first';
  exception when sqlstate 'P0001' then raise notice 'ok: leg 2 waits for leg 1'; end;

  perform play_game(leg(1, 1, 1), 2, 2);
  raise notice 'ok: a first leg can be level';

  begin
    perform play_game(leg(1, 1, 2), 1, 1);
    raise exception 'TEST FAILED: level aggregate accepted with no shootout winner';
  exception when sqlstate 'P0001' then raise notice 'ok: level aggregate needs a shootout winner'; end;

  -- 2–2, 1–1: level, and team_b wins the shootout. The score stays a tie.
  perform play_game(leg(1, 1, 2), 1, 1, (select team_b from matches where id = leg(1, 1, 1)));
  if (select score_a || '-' || score_b from matches where id = leg(1, 1, 2)) <> '1-1'
     or (select winner_id from matches where id = leg(1, 1, 2)) is not null then
    raise exception 'TEST FAILED: the shootout changed the score';
  end if;
  raise notice 'ok: penalties do not touch the score';
  if (select team_b from matches where phase='playoff' and round=2 and slot=0 and leg=1)
     <> (select team_b from matches where id = leg(1, 1, 1)) then
    raise exception 'TEST FAILED: the shootout winner did not advance';
  end if;
  raise notice 'ok: shootout winner advances into the semi';
  if (select body from messages where match_id = leg(1, 1, 2) and kind = 'result') not like '%win on penalties' then
    raise exception 'TEST FAILED: the result line does not mention the shootout';
  end if;
  raise notice 'ok: chat says who won on penalties';

  -- Semi 0 now has both teams: #1 hosts the second leg.
  if (select home_team from matches where id = leg(2, 0, 2))
     <> (select team_id from standings where rank = 1) then
    raise exception 'TEST FAILED: #1 should host the second leg of the semi';
  end if;
  raise notice 'ok: semi homes set once both teams are known';
end $$;

\echo '=== 19. play the rest to a champion; results reach the chat ==='
do $$ declare before int; begin
  select count(*) into before from messages where kind='result';
  perform play_tie(1, 2);
  perform play_tie(1, 3);
  if (select count(*) from messages where kind='result') <> before + 4 then
    raise exception 'TEST FAILED: playoff results did not all reach the chat';
  end if;
  raise notice 'ok: round 1 finished, every leg announced';

  perform play_tie(2, 0);
  perform play_tie(2, 1);

  begin
    perform play_game(leg(3, 0, 1), 1, 1);
    raise exception 'TEST FAILED: a level final with no shootout winner';
  exception when sqlstate 'P0001' then raise notice 'ok: a level final needs a shootout winner'; end;

  begin
    perform play_game(leg(3, 0, 1), 1, 1, (select team_id from standings where rank = 7));
    raise exception 'TEST FAILED: shootout won by a team not in the final';
  exception when sqlstate 'P0001' then raise notice 'ok: shootout winner must be in the game'; end;

  -- 1–1 in the final, team_b takes it on penalties.
  perform play_game(leg(3, 0, 1), 1, 1, (select team_b from matches where id = leg(3, 0, 1)));
  if (select phase from league_settings) <> 'complete'
     or (select champion_team_id from league_settings)
        is distinct from (select team_b from matches where id = leg(3, 0, 1)) then
    raise exception 'TEST FAILED: the shootout winner was not crowned';
  end if;
  raise notice 'ok: champion crowned on penalties, final stays 1–1';
end $$;

select ls.phase, t.name as champion
  from league_settings ls left join teams t on t.id = ls.champion_team_id;

\echo '=== 20. voiding the final clears the champion and its announcement ==='
do $$ declare mid uuid; begin
  perform act_as('Mati');
  mid := leg(3, 0, 1);
  perform admin_void_match(mid, 'replayed');
  if (select champion_team_id from league_settings) is not null then
    raise exception 'TEST FAILED: champion survived the void';
  end if;
  if (select phase from league_settings) <> 'playoffs' then
    raise exception 'TEST FAILED: phase did not roll back to playoffs';
  end if;
  if exists (select 1 from messages where match_id = mid) then
    raise exception 'TEST FAILED: the final''s announcement survived the void';
  end if;
  raise notice 'ok: voided final rolled everything back';
end $$;

\echo '=== 21. voiding a semi leg wipes the final slot it fed ==='
do $$ begin
  perform act_as('Mati');
  perform admin_void_match(leg(2, 0, 1), 'protest upheld');
  if (select team_a from matches where id = leg(3, 0, 1)) is not null then
    raise exception 'TEST FAILED: the final kept a team from a voided semi';
  end if;
  raise notice 'ok: final slot cleared';

  begin
    perform admin_void_match((select id from matches where phase='playoff' and status='bye'), 'no');
    raise exception 'TEST FAILED: voided a bye';
  exception when sqlstate 'P0001' then raise notice 'ok: byes cannot be voided'; end;

  -- An admin rewrite of leg 1 is held to the aggregate rule, too.
  begin
    perform admin_resolve_match(leg(2, 0, 2),
      (select score_a from matches where id = leg(2, 0, 2)),
      (select score_b from matches where id = leg(2, 0, 2)), 'x');
    raise exception 'TEST FAILED: admin settled leg 2 with leg 1 unplayed';
  exception when sqlstate 'P0001' then raise notice 'ok: admin follows leg order'; end;
end $$;

\echo '=== 22. bracket sizes follow the team count ==='
do $$ declare t uuid; begin
  perform act_as('Mati');
  perform admin_reset_playoffs();
  for t in select id from teams where not is_active loop
    perform admin_update_team(t, (select name from teams where id = t), true,
                              (select paid from teams where id = t));
  end loop;

  -- 10 teams: a 16 bracket, so the top 6 seeds get byes.
  perform admin_start_playoffs();
  if (select count(*) from matches where phase='playoff' and status='bye') <> 6 then
    raise exception 'TEST FAILED: 10 teams should mean 6 byes';
  end if;
  if exists (select 1 from matches m join standings s on s.team_id = m.team_a
              where m.phase='playoff' and m.status='bye' and s.rank > 6) then
    raise exception 'TEST FAILED: a bye went to somebody outside the top 6';
  end if;
  raise notice 'ok: 10 teams — top 6 seeds get byes';

  -- 8 teams: a full bracket, no byes.
  perform admin_reset_playoffs();
  for t in select team_id from standings order by rank desc limit 2 loop
    perform admin_update_team(t, (select name from teams where id = t), false,
                              (select paid from teams where id = t));
  end loop;
  perform admin_start_playoffs();
  if exists (select 1 from matches where phase='playoff' and status='bye') then
    raise exception 'TEST FAILED: 8 teams should not need a bye';
  end if;
  raise notice 'ok: 8 teams — no byes';

  perform admin_reset_playoffs();
  for t in select id from teams where not is_active loop
    perform admin_update_team(t, (select name from teams where id = t), true,
                              (select paid from teams where id = t));
  end loop;
end $$;
