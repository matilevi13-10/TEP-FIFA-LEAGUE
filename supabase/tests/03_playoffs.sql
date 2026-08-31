\set ON_ERROR_STOP on
\pset pager off

create or replace function play_po(w text, l text, ws int, ls int) returns void
language plpgsql as $$
declare mid uuid; wi uuid; li uuid; begin
  select id into wi from teams where name=w;
  select id into li from teams where name=l;
  select id into mid from matches where phase='playoff'
    and ((team_a=wi and team_b=li) or (team_a=li and team_b=wi))
    and status in ('scheduled','disputed');
  if mid is null then raise exception 'no open bracket match for % vs %', w, l; end if;
  perform act_as_team(w);
  perform submit_playoff_result(mid, ws, ls);
  perform act_as_team(l);
  perform confirm_match(mid);
end $$;

\echo '=== 16. start an 8-team playoff ==='
select act_as('Mati');
select admin_start_playoffs(8);
select phase, playoff_size from league_settings;
select m.slot, m.seed_a, ta.name as team_a, m.seed_b, tb.name as team_b
  from matches m join teams ta on ta.id=m.team_a join teams tb on tb.id=m.team_b
 where m.phase='playoff' and m.round=1 order by m.slot;

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

\echo '=== 18. no draws in the playoffs ==='
do $$ declare mid uuid; t text; begin
  select id into mid from matches where phase='playoff' and round=1 and slot=0;
  select name into t from teams where id = (select team_a from matches where id=mid);
  perform act_as_team(t);
  begin
    perform submit_playoff_result(mid, 2, 2);
    raise exception 'TEST FAILED: a playoff draw was accepted';
  exception when sqlstate 'P0001' then raise notice 'ok: playoff level score rejected'; end;
end $$;

\echo '=== 19. play the bracket to a champion; results reach the chat ==='
do $$ declare seeds text; begin
  select string_agg(t.name, ', ' order by s.rank) into seeds
    from standings s join teams t on t.id = s.team_id where s.rank <= 8;
  raise notice 'seeds: %', seeds;
end $$;

do $$
declare r record; before int;
begin
  select count(*) into before from messages where kind='result';
  -- play whatever round 1 the seeding produced: higher seed wins every game
  for r in select m.id, ta.name a, tb.name b, m.seed_a, m.seed_b
             from matches m join teams ta on ta.id=m.team_a join teams tb on tb.id=m.team_b
            where m.phase='playoff' and m.round=1 order by m.slot
  loop
    if r.seed_a < r.seed_b then perform play_po(r.a, r.b, 2, 0);
    else perform play_po(r.b, r.a, 2, 0); end if;
  end loop;
  if (select count(*) from messages where kind='result') <> before + 4 then
    raise exception 'TEST FAILED: playoff results did not all reach the chat';
  end if;
  raise notice 'ok: round 1 played, all 4 announced';
end $$;

\echo '--- semi-finals populated by the trigger ---'
select m.slot, m.seed_a, ta.name as team_a, m.seed_b, tb.name as team_b
  from matches m left join teams ta on ta.id=m.team_a left join teams tb on tb.id=m.team_b
 where m.phase='playoff' and m.round=2 order by m.slot;

do $$
declare r record;
begin
  for r in select m.id, ta.name a, tb.name b, m.seed_a, m.seed_b
             from matches m join teams ta on ta.id=m.team_a join teams tb on tb.id=m.team_b
            where m.phase='playoff' and m.round=2 order by m.slot
  loop
    if r.seed_a < r.seed_b then perform play_po(r.a, r.b, 3, 1);
    else perform play_po(r.b, r.a, 3, 1); end if;
  end loop;
  for r in select m.id, ta.name a, tb.name b, m.seed_a, m.seed_b
             from matches m join teams ta on ta.id=m.team_a join teams tb on tb.id=m.team_b
            where m.phase='playoff' and m.round=3
  loop
    if r.seed_a < r.seed_b then perform play_po(r.a, r.b, 1, 0);
    else perform play_po(r.b, r.a, 1, 0); end if;
  end loop;
end $$;

select ls.phase, t.name as champion
  from league_settings ls left join teams t on t.id = ls.champion_team_id;

\echo '=== 20. voiding the final clears the champion and its announcement ==='
do $$ declare mid uuid; begin
  perform act_as('Mati');
  select id into mid from matches where phase='playoff' and round=3 and slot=0;
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

\echo '=== 21. voiding a semi wipes the final slot it fed ==='
do $$ declare mid uuid; begin
  perform act_as('Mati');
  select id into mid from matches where phase='playoff' and round=2 and slot=0;
  perform admin_void_match(mid, 'protest upheld');
end $$;
select round, slot, ta.name as team_a, tb.name as team_b, m.status
  from matches m left join teams ta on ta.id=m.team_a left join teams tb on tb.id=m.team_b
 where m.phase='playoff' and m.round >= 2 order by round, slot;

\echo '=== 22. bracket sizes ==='
do $$ begin
  perform act_as('Mati');
  perform admin_reset_playoffs();
  perform admin_start_playoffs(4);
  if (select count(*) from matches where phase='playoff') <> 3 then
    raise exception 'TEST FAILED: a 4-team bracket should have 3 matches';
  end if;
  raise notice 'ok: 4-team bracket has 3 matches';
  perform admin_reset_playoffs();
  begin
    perform admin_start_playoffs(16);
    raise exception 'TEST FAILED: 16-team bracket built from 8 teams';
  exception when sqlstate 'P0001' then raise notice 'ok: refuses a 16-bracket with only 8 teams'; end;
end $$;
