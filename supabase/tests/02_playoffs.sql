\set ON_ERROR_STOP on
\pset pager off

-- Plays a bracket match: winner submits, loser confirms.
create or replace function play_po(p_winner text, p_loser text, p_ws int, p_ls int)
returns void language plpgsql as $$
declare mid uuid; w uuid; l uuid;
begin
  select id into w from teams where name=p_winner;
  select id into l from teams where name=p_loser;
  select id into mid from matches
   where phase='playoff' and ((team_a=w and team_b=l) or (team_a=l and team_b=w))
     and status in ('scheduled','disputed');
  if mid is null then raise exception 'no open bracket match for % vs %', p_winner, p_loser; end if;
  perform act_as(p_winner);
  perform submit_playoff_result(mid, p_ws, p_ls);
  perform act_as(p_loser);
  perform confirm_match(mid);
end $$;

\echo '=== 8. start an 8-team playoff ==='
do $$ begin perform act_as('Admin'); end $$;
select admin_start_playoffs(8);
select phase, playoff_size from league_settings;

\echo '--- round 1 seeding (1v8, 4v5, 3v6, 2v7 across the bracket) ---'
select m.slot, m.seed_a, ta.name as team_a, m.seed_b, tb.name as team_b
  from matches m join teams ta on ta.id=m.team_a join teams tb on tb.id=m.team_b
 where m.phase='playoff' and m.round=1 order by m.slot;
select round, count(*) as slots from matches where phase='playoff' group by round order by round;

\echo '=== 9. league is locked once playoffs start ==='
do $$ declare b uuid; begin
  perform act_as('Alpha');
  select id into b from teams where name='Bravo';
  begin
    perform submit_league_result(b, 3, 0);
    raise exception 'TEST FAILED: league submission accepted after lock';
  exception when sqlstate 'P0001' then raise notice 'ok: league phase locked'; end;
end $$;

\echo '=== 10. draws are rejected in the playoffs ==='
do $$ declare mid uuid; begin
  select id into mid from matches where phase='playoff' and round=1 and slot=0;
  perform act_as((select name from teams where id=(select team_a from matches where id=mid)));
  begin
    perform submit_playoff_result(mid, 2, 2);
    raise exception 'TEST FAILED: a playoff draw was accepted';
  exception when sqlstate 'P0001' then raise notice 'ok: playoff draw rejected'; end;
end $$;

\echo '=== 11. play the bracket through to a champion ==='
-- seeds: 1 Alpha, 2 Bravo, 3 Golf, 4 Foxtrot, 5 Delta, 6 Charlie, 7 Hotel, 8 Echo
select play_po('Alpha','Echo',3,0);      -- 1v8
select play_po('Foxtrot','Delta',2,1);   -- 4v5
select play_po('Golf','Charlie',2,0);    -- 3v6
select play_po('Bravo','Hotel',4,1);     -- 2v7
\echo '--- semi-finals should now be populated ---'
select m.slot, m.seed_a, ta.name as team_a, m.seed_b, tb.name as team_b
  from matches m left join teams ta on ta.id=m.team_a left join teams tb on tb.id=m.team_b
 where m.phase='playoff' and m.round=2 order by m.slot;

select play_po('Alpha','Foxtrot',2,1);
select play_po('Bravo','Golf',3,2);
\echo '--- final ---'
select m.seed_a, ta.name as team_a, m.seed_b, tb.name as team_b
  from matches m left join teams ta on ta.id=m.team_a left join teams tb on tb.id=m.team_b
 where m.phase='playoff' and m.round=3;

select play_po('Bravo','Alpha',2,1);
select ls.phase, t.name as champion
  from league_settings ls left join teams t on t.id=ls.champion_team_id;

\echo '=== 12. admin voids the final — champion and downstream must clear ==='
do $$ declare mid uuid; begin
  perform act_as('Admin');
  select id into mid from matches where phase='playoff' and round=3 and slot=0;
  perform admin_void_match(mid, 'replayed');
end $$;
select ls.phase, ls.champion_team_id is null as champion_cleared,
       (select status from matches where phase='playoff' and round=3) as final_status
  from league_settings ls;

\echo '=== 13. voiding a semi must wipe the final slot it fed ==='
do $$ declare mid uuid; begin
  perform act_as('Admin');
  select id into mid from matches where phase='playoff' and round=2 and slot=0;
  perform admin_void_match(mid, 'protest upheld');
end $$;
select round, slot, ta.name as team_a, tb.name as team_b, m.status
  from matches m left join teams ta on ta.id=m.team_a left join teams tb on tb.id=m.team_b
 where m.phase='playoff' and m.round >= 2 order by round, slot;

\echo '=== 14. replay the semi with the other result; bracket must re-fill ==='
select play_po('Foxtrot','Alpha',3,2);
select play_po('Foxtrot','Bravo',1,0);
select ls.phase, t.name as champion
  from league_settings ls left join teams t on t.id=ls.champion_team_id;
