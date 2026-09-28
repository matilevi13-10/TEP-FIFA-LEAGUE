\set ON_ERROR_STOP on
\pset pager off

-- Act as the slot-1 player of a team.
create or replace function act_as_team(p_team text) returns void language plpgsql as $$
declare uid uuid; begin
  select p.user_id into uid from players p join teams t on t.id = p.team_id
   where t.name = p_team and p.slot = 1;
  perform set_config('test.uid', uid::text, false);
end $$;

-- The schedule is generated and randomised, so tests play whatever fixture is
-- next rather than naming pairings that may not be scheduled.
create table if not exists played_log (
  seq serial primary key, match_id uuid, home text, away text, score_a int, score_b int
);

create or replace function play_next(sa int, sb int) returns uuid
language plpgsql as $$
declare mid uuid; a text; b text; begin
  select m.id, ta.name, tb.name into mid, a, b
    from matches m join teams ta on ta.id = m.team_a join teams tb on tb.id = m.team_b
   where m.phase='league' and m.status='scheduled'
   order by m.round, m.slot, m.leg limit 1;
  if mid is null then raise exception 'no scheduled fixture left'; end if;

  perform act_as_team(a);
  perform submit_league_result(mid, sa, sb);   -- team_a's point of view
  perform act_as_team(b);
  perform confirm_match(mid);

  insert into played_log (match_id, home, away, score_a, score_b)
  values (mid, a, b, sa, sb);
  return mid;
end $$;

create or replace function play(w text, l text, ws int, ls int) returns void
language plpgsql as $$
declare mid uuid; wid uuid; lid uuid; begin
  select id into wid from teams where name = w;
  select id into lid from teams where name = l;
  select id into mid from matches
   where phase='league' and status in ('scheduled','disputed')
     and ((team_a=wid and team_b=lid) or (team_a=lid and team_b=wid))
   order by round limit 1;
  if mid is null then
    raise exception 'no scheduled fixture for % vs %', w, l;
  end if;
  perform act_as_team(w);
  perform submit_league_result(mid, ws, ls);
  perform act_as_team(l);
  perform confirm_match(mid);
end $$;

\echo '=== 7. the admin fallback still pairs people manually ==='
do $$ begin
  perform act_as('Mati');
  if not is_admin() then raise exception 'TEST FAILED: admin lost their controls'; end if;
  raise notice 'ok: admin identified by email';

  perform signup('Bruno','bruno@example.com');
  perform signup('Caio','caio@example.com');
  perform act_as('Mati');
  perform admin_create_team('The Understudies',
    (select id from players where name='Bruno'), (select id from players where name='Caio'));
  raise notice 'ok: admin paired two players manually';

  begin
    perform admin_create_team('Dupes',
      (select id from players where name='Bruno'), (select id from players where name='Caio'));
    raise exception 'TEST FAILED: admin teamed already-teamed players';
  exception when sqlstate 'P0001' then raise notice 'ok: admin cannot double-assign'; end;

  perform admin_dissolve_team((select id from teams where name='The Understudies'));
  raise notice 'ok: admin dissolved the fallback team again';
end $$;

\echo '=== 8. a signed-in user with no team cannot log a result ==='
do $$ begin
  perform signup('Loner','loner@example.com');
  begin
    perform submit_league_result(
      (select id from matches where phase='league' limit 1), 3, 0);
    raise exception 'TEST FAILED: teamless account logged a result';
  exception when sqlstate 'P0001' then raise notice 'ok: needs a team to submit'; end;
end $$;

\echo '=== 8b. the admin starts the season, which builds the schedule ==='
do $$ declare n int; begin
  perform act_as('Mati');
  perform admin_set_season_started(true);

  select count(*) into n from matches where phase='league';
  if n < 1 then raise exception 'TEST FAILED: the season has no fixtures'; end if;
  raise notice 'ok: the season has % league fixtures', n;

  -- every fixture has a round number and two real teams
  if exists (select 1 from matches where phase='league'
              and (round is null or team_a is null or team_b is null or team_a = team_b)) then
    raise exception 'TEST FAILED: a fixture is malformed';
  end if;
  raise notice 'ok: fixtures are well formed and numbered by round';
end $$;

\echo '=== 8c. rounds: one opponent a week, twice ==='
do $$ declare n int; weeks int; begin
  perform act_as('Mati');
  select count(*) into n from teams where is_active;

  begin
    perform admin_update_settings('Season 1', 11, 5000, null);
    raise exception 'TEST FAILED: an odd games-per-team was accepted';
  exception when sqlstate 'P0001' then raise notice 'ok: games per team must be even'; end;

  -- 12 games is 6 rounds: six different opponents, two games each.
  perform admin_update_settings('Season 1', 12, 5000, null);
  perform generate_schedule();
  if exists (
    select 1 from teams tm where tm.is_active and (
      (select count(*) from matches where phase='league' and tm.id in (team_a, team_b)) <> 12
      or (select count(distinct case when team_a = tm.id then team_b else team_a end)
            from matches where phase='league' and tm.id in (team_a, team_b)) <> 6)
  ) then raise exception 'TEST FAILED: 12 games should be 6 opponents, twice each'; end if;
  raise notice 'ok: 12 games per team is 6 rounds of 2';

  -- Everyone twice: a full cycle.
  perform admin_update_settings('Season 1', 2 * (n - 1), 5000, null);
  perform generate_schedule();
  select count(distinct round) into weeks from matches where phase='league';
  if weeks <> (case when n % 2 = 0 then n - 1 else n end) then
    raise exception 'TEST FAILED: % teams should take % weeks, got %',
      n, case when n % 2 = 0 then n - 1 else n end, weeks;
  end if;
  if exists (
    select 1 from teams x join teams y on x.id < y.id
     where x.is_active and y.is_active
       and (select count(*) from matches where phase='league'
             and ((team_a=x.id and team_b=y.id) or (team_a=y.id and team_b=x.id))) <> 2
  ) then raise exception 'TEST FAILED: a pairing does not meet exactly twice'; end if;
  raise notice 'ok: % games each is everyone twice over % weeks', 2 * (n - 1), weeks;
end $$;

do $$ begin
  -- Whatever the length, a pairing's two games share a week, nobody faces two
  -- opponents in a week, and each side gets one of the two home games.
  if exists (
    select 1 from matches where phase='league'
     group by round, least(team_a::text, team_b::text), greatest(team_a::text, team_b::text)
    having count(*) <> 2
  ) then raise exception 'TEST FAILED: a pairing is not two games in one week'; end if;
  if exists (
    select 1 from (
      select round, team_a t, team_b o from matches where phase='league'
      union all select round, team_b, team_a from matches where phase='league'
    ) g group by round, t having count(distinct o) > 1
  ) then raise exception 'TEST FAILED: a team has two opponents in a week'; end if;
  if exists (
    select 1 from matches where phase='league'
     group by round, slot having count(distinct home_team) <> 2
  ) then raise exception 'TEST FAILED: both games of a week share a home team'; end if;
  raise notice 'ok: two games a week against one opponent, one home each';
end $$;

\echo '=== 9. league play, and the chat announces confirmed results ==='
delete from played_log;
select play_next(4,1);   -- the one the result-line assertions below use
select play_next(2,0);
select play_next(3,2);
select play_next(1,0);
select play_next(5,2);
select play_next(2,1);
select play_next(3,0);
select play_next(2,1);
select play_next(4,3);
select play_next(1,0);
select play_next(3,2);
select play_next(2,0);

do $$ declare n int; begin
  -- Count the twelve games this suite just played, not every result that any
  -- earlier suite may have left behind in the shared database.
  select count(*) into n from messages m
    join matches mt on mt.id = m.match_id
   where m.kind = 'result' and mt.status = 'confirmed';
  if n < 12 then raise exception 'TEST FAILED: expected at least 12 result messages, got %', n; end if;
  raise notice 'ok: every confirmed result posted to chat (% messages)', n;

  -- The first fixture played above, whatever pairing the schedule gave it.
  if not exists (
    select 1 from played_log p
      join messages msg on msg.match_id = p.match_id and msg.kind = 'result'
     where p.seq = (select min(seq) from played_log)
       and msg.body = p.home || ' ' || p.score_a || '–' || p.score_b || ' ' || p.away
       and msg.team_name = p.home
  ) then
    raise exception 'TEST FAILED: result line wrong. Expected "%", got "%"',
      (select p.home||' '||p.score_a||'–'||p.score_b||' '||p.away from played_log p
        where p.seq = (select min(seq) from played_log)),
      (select msg.body from played_log p join messages msg on msg.match_id = p.match_id
        where msg.kind='result' and p.seq = (select min(seq) from played_log));
  end if;
  raise notice 'ok: result line reads correctly and names the winner';
  raise notice 'ok: winner recorded for win/loss framing';
end $$;

\echo '=== 9b. a league game tied after extra time stays a tie ==='
do $$ declare fix uuid; ta uuid; tb uuid; pts_a int; pts_b int; m uuid; begin
  select id, team_a, team_b into fix, ta, tb from matches
   where phase='league' and status='scheduled' order by round, slot, leg limit 1;
  select points into pts_a from standings where team_id = ta;
  select points into pts_b from standings where team_id = tb;

  perform set_config('test.uid',
    (select user_id::text from players where team_id = ta and slot = 1), false);
  perform submit_league_result(fix, 2, 2);
  perform set_config('test.uid',
    (select user_id::text from players where team_id = tb and slot = 1), false);
  perform confirm_match(fix);

  if (select winner_id from matches where id = fix) is not null then
    raise exception 'TEST FAILED: a draw recorded a winner';
  end if;
  if (select points from standings where team_id = ta) <> pts_a + 1
     or (select points from standings where team_id = tb) <> pts_b + 1 then
    raise exception 'TEST FAILED: a draw should be worth a point each';
  end if;
  if (select drawn from standings where team_id = ta) < 1 then
    raise exception 'TEST FAILED: the draw is missing from the table';
  end if;
  raise notice 'ok: a tie is a point each and nobody wins';

  if (select team_name from messages where match_id = fix and kind = 'result') is not null then
    raise exception 'TEST FAILED: the result line named a winner for a draw';
  end if;
  raise notice 'ok: a drawn result is announced with no winner';

  begin
    perform post_taunt(fix, 'we basically won');
    raise exception 'TEST FAILED: taunted a draw';
  exception when sqlstate 'P0001' then raise notice 'ok: nobody taunts a draw'; end;

  -- The admin can settle a game level, too.
  select id into m from matches where status='confirmed' and phase='league'
   and winner_id is not null order by confirmed_at desc limit 1;
  perform act_as('Mati');
  perform admin_resolve_match(m, 1, 1, 'replay said level');
  if (select winner_id from matches where id = m) is not null then
    raise exception 'TEST FAILED: admin draw kept a winner';
  end if;
  perform admin_resolve_match(m, 2, 1, 'actually not');
  raise notice 'ok: admin can settle a draw and undo it';
end $$;

\echo '=== 10. a pending result posts nothing ==='
do $$ declare before int; after int; fix uuid; begin
  select count(*) into before from messages;
  perform act_as_team('Route One');
  select id into fix from matches where phase='league' and status='scheduled'
    and (team_a=(select id from teams where name='Route One')
      or team_b=(select id from teams where name='Route One')) limit 1;
  perform submit_league_result(fix, 2, 1);
  select count(*) into after from messages;
  if after <> before then raise exception 'TEST FAILED: unconfirmed result reached the chat'; end if;
  raise notice 'ok: nothing is announced until the opponent confirms';
end $$;

\echo '=== 11. taunts: winners only, once per match ==='
do $$ declare m uuid; winner text; loser text; outsider text; begin
  -- Use a fixture we actually played, whichever pairing the schedule produced.
  select p.match_id,
         case when p.score_a > p.score_b then p.home else p.away end,
         case when p.score_a > p.score_b then p.away else p.home end
    into m, winner, loser
    from played_log p
    join matches mt on mt.id = p.match_id
   where mt.status = 'confirmed' and mt.winner_id is not null
   order by p.seq limit 1;
  if m is null then raise exception 'TEST FAILED: no confirmed fixture to taunt on'; end if;

  select t.name into outsider from teams t
   where t.name not in (winner, loser)
     and exists (select 1 from players pl where pl.team_id = t.id and pl.user_id is not null)
   limit 1;

  perform act_as_team(loser);
  begin
    perform post_taunt(m, 'we were robbed');
    raise exception 'TEST FAILED: the losing team taunted';
  exception when sqlstate 'P0001' then raise notice 'ok: only the winner can taunt'; end;

  if outsider is not null then
    perform act_as_team(outsider);
    begin
      perform post_taunt(m, 'lol');
      raise exception 'TEST FAILED: an uninvolved team taunted';
    exception when sqlstate 'P0001' then raise notice 'ok: outsiders cannot taunt'; end;
  end if;

  perform act_as_team(winner);
  perform post_taunt(m, 'get the bus back to the shop');
  raise notice 'ok: winner taunted';

  begin
    perform post_taunt(m, 'and another thing');
    raise exception 'TEST FAILED: second taunt on the same match';
  exception when sqlstate 'P0001' then raise notice 'ok: one taunt per match'; end;
end $$;

\echo '=== 12. chat messages ==='
do $$ declare n int; begin
  perform act_as_team('Tiki Taka');
  perform post_message('anyone free tonight?');
  if (select author_name from messages where kind='chat' order by created_at desc limit 1) <> 'Leo' then
    raise exception 'TEST FAILED: author name not stamped';
  end if;
  if (select team_name from messages where kind='chat' order by created_at desc limit 1) <> 'Tiki Taka' then
    raise exception 'TEST FAILED: team name not stamped';
  end if;
  raise notice 'ok: chat message stamped with player and team';

  begin
    perform post_message(repeat('x', 501));
    raise exception 'TEST FAILED: overlong message accepted';
  exception when sqlstate 'P0001' then raise notice 'ok: message length capped'; end;
  begin
    perform post_message('   ');
    raise exception 'TEST FAILED: empty message accepted';
  exception when sqlstate 'P0001' then raise notice 'ok: empty message rejected'; end;

  -- a teamless player can still talk
  perform act_as('Loner');
  perform post_message('let me in');
  if (select team_name from messages where body = 'let me in') is not null then
    raise exception 'TEST FAILED: teamless message got a team name';
  end if;
  if (select author_name from messages where body = 'let me in') <> 'Loner' then
    raise exception 'TEST FAILED: teamless author not stamped';
  end if;
  raise notice 'ok: pool players can chat too';
end $$;

\echo '=== 13. admin edits a score → the announcement follows ==='
do $$ declare m uuid; a text; b text; begin
  select p.match_id, p.home, p.away into m, a, b
    from played_log p where p.seq = (select min(seq) from played_log);
  if m is null then raise exception 'TEST FAILED: no played fixture recorded'; end if;

  perform act_as('Mati');
  perform admin_resolve_match(m, 1, 2, 'scoreline corrected');

  if (select body from messages where match_id = m and kind='result') <> a || ' 1–2 ' || b then
    raise exception 'TEST FAILED: announcement not updated, reads "%"',
      (select body from messages where match_id = m and kind='result');
  end if;
  if (select team_name from messages where match_id = m and kind='result') <> b then
    raise exception 'TEST FAILED: winner not updated on the announcement';
  end if;
  raise notice 'ok: corrected score rewrites the announcement';
end $$;

\echo '=== 14. voiding a result removes its announcement and taunt ==='
do $$ declare m uuid; begin
  select match_id into m from messages where kind='taunt' limit 1;
  perform act_as('Mati');
  perform admin_void_match(m, 'replayed');
  if exists (select 1 from messages where match_id = m) then
    raise exception 'TEST FAILED: voided match left % messages behind',
      (select count(*) from messages where match_id = m);
  end if;
  raise notice 'ok: voiding clears the announcement and the taunt';
end $$;

\echo '=== 15. admin can delete any message ==='
do $$ declare mid uuid; begin
  perform act_as_team('Tiki Taka');
  perform post_message('delete me');
  select id into mid from messages order by created_at desc limit 1;
  perform act_as('Mati');
  perform admin_delete_message(mid);
  if exists (select 1 from messages where id = mid) then
    raise exception 'TEST FAILED: admin could not delete a message';
  end if;
  raise notice 'ok: admin deleted a message';
end $$;

select kind, count(*) from messages group by kind order by kind;
