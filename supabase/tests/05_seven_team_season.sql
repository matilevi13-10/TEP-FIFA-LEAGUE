\set ON_ERROR_STOP on
\pset pager off

-- The league as the rules describe it: seven teams, 12 games each — 6 rounds,
-- played over seven weeks with one week off each.
-- Runs last, because rebuilding the schedule deletes every league result.
\echo '=== 29. seven teams make a seven-week season ==='
do $$ declare t uuid; begin
  perform act_as('Mati');
  for t in select team_id from standings order by rank desc limit 3 loop
    perform admin_update_team(t, (select name from teams where id = t), false,
                              (select paid from teams where id = t));
  end loop;
  perform admin_update_settings('Season 1', 12, 5000, null);
  perform generate_schedule();

  if (select count(distinct round) from matches where phase='league') <> 7 then
    raise exception 'TEST FAILED: 7 teams should play over 7 weeks';
  end if;
  if exists (
    select 1 from teams tm where tm.is_active and
      (select count(*) from matches where phase='league' and tm.id in (team_a, team_b)) <> 12
  ) then raise exception 'TEST FAILED: every team should play 12 games'; end if;
  -- Each team plays in six weeks and sits exactly one out.
  if exists (
    select 1 from teams tm where tm.is_active and
      (select count(distinct round) from matches where phase='league' and tm.id in (team_a, team_b)) <> 6
  ) then raise exception 'TEST FAILED: every team should have exactly one week off'; end if;
  if exists (
    select 1 from teams tm where tm.is_active and
      (select count(*) from matches where phase='league' and home_team = tm.id) <> 6
  ) then raise exception 'TEST FAILED: every team should get 6 home games'; end if;
  raise notice 'ok: 7 weeks, 12 games each, one week off, 6 at home';
end $$;
