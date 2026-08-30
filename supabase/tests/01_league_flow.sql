\set ON_ERROR_STOP on
\pset pager off

-- Simulates the client sign-in round trip: begin_signin → signUp → link_account.
create or replace function test_signin(p_team text, p_pin text) returns uuid
language plpgsql as $$
declare tid uuid; info json; uid uuid; existing uuid;
begin
  select id into tid from teams where name = p_team;
  select user_id into existing from teams where id = tid;
  info := begin_signin(tid, p_pin);
  if (info->>'needs_signup')::boolean then
    insert into auth.users (email) values (info->>'email') returning id into uid;
    perform set_config('test.uid', uid::text, false);
    perform link_account(tid, p_pin);
  else
    uid := existing;
    perform set_config('test.uid', uid::text, false);
  end if;
  return uid;
end $$;

create or replace function act_as(p_team text) returns void language plpgsql as $$
declare uid uuid;
begin
  select user_id into uid from teams where name = p_team;
  perform set_config('test.uid', uid::text, false);
end $$;

-- Plays a full league game: winner submits, loser confirms.
create or replace function play(p_winner text, p_loser text, p_ws int, p_ls int)
returns void language plpgsql as $$
declare mid uuid; lid uuid;
begin
  perform act_as(p_winner);
  select id into lid from teams where name = p_loser;
  mid := submit_league_result(lid, p_ws, p_ls);
  perform act_as(p_loser);
  perform confirm_match(mid);
end $$;

\echo '=== 1. admin signs in and creates 8 teams ==='
select test_signin('Admin', '1234') is not null as admin_linked;
select is_admin() as admin_flag_set;

select admin_create_team('Alpha',  'Mati','Nico','1111') is not null as t1;
select admin_create_team('Bravo',  'Leo','Juan','2222')  is not null as t2;
select admin_create_team('Charlie','Tom','Ben','3333')   is not null as t3;
select admin_create_team('Delta',  'Sam','Max','4444')   is not null as t4;
select admin_create_team('Echo',   'Ari','Dan','5555')   is not null as t5;
select admin_create_team('Foxtrot','Ivo','Gus','6666')   is not null as t6;
select admin_create_team('Golf',   'Rui','Pep','7777')   is not null as t7;
select admin_create_team('Hotel',  'Kai','Ozzy','8888')  is not null as t8;
select count(*) as teams_created from teams where is_active;

\echo '=== 2. wrong PIN is rejected, right PIN works ==='
do $$ begin
  begin
    perform begin_signin((select id from teams where name='Alpha'), '0000');
    raise exception 'TEST FAILED: wrong PIN was accepted';
  exception when sqlstate 'P0001' then raise notice 'ok: wrong PIN rejected'; end;
end $$;
select test_signin('Alpha','1111') is not null as alpha_linked;

\echo '=== 3. loser cannot submit; tie can be submitted by either ==='
do $$ declare bravo uuid; begin
  perform act_as('Alpha');
  select id into bravo from teams where name='Bravo';
  begin
    perform submit_league_result(bravo, 1, 3);
    raise exception 'TEST FAILED: the losing team was allowed to submit';
  exception when sqlstate 'P0001' then raise notice 'ok: loser blocked'; end;
end $$;

do $$ declare alpha uuid; begin
  perform act_as('Alpha');
  select id into alpha from teams where name='Alpha';
  begin
    perform submit_league_result(alpha, 2, 1);
    raise exception 'TEST FAILED: a team played itself';
  exception when sqlstate 'P0001' then raise notice 'ok: self-match blocked'; end;
end $$;

\echo '=== 4. nothing counts until the opponent confirms ==='
do $$ declare bravo uuid; mid uuid; begin
  perform act_as('Alpha');
  select id into bravo from teams where name='Bravo';
  mid := submit_league_result(bravo, 3, 1);
  if (select played from standings where name='Alpha') <> 0 then
    raise exception 'TEST FAILED: a pending match already moved the table';
  end if;
  raise notice 'ok: pending match does not count';
  -- submitter may not confirm their own result
  begin
    perform confirm_match(mid);
    raise exception 'TEST FAILED: submitter confirmed their own match';
  exception when sqlstate 'P0001' then raise notice 'ok: self-confirm blocked'; end;
  perform test_signin('Bravo','2222');
  perform confirm_match(mid);
  if (select played from standings where name='Alpha') <> 1 then
    raise exception 'TEST FAILED: confirmed match did not land in the table';
  end if;
  raise notice 'ok: confirmed match counts';
end $$;

\echo '=== 5. link every remaining team, then play a full slate ==='
select test_signin('Charlie','3333') is not null,
       test_signin('Delta','4444')   is not null,
       test_signin('Echo','5555')    is not null,
       test_signin('Foxtrot','6666') is not null,
       test_signin('Golf','7777')    is not null,
       test_signin('Hotel','8888')   is not null;

select play('Alpha','Charlie',4,0);
select play('Alpha','Delta',2,1);
select play('Bravo','Charlie',3,2);
select play('Bravo','Delta',1,0);
select play('Charlie','Echo',5,1);
select play('Delta','Echo',2,0);
select play('Echo','Foxtrot',3,1);
select play('Foxtrot','Golf',2,1);
select play('Golf','Hotel',4,2);
select play('Hotel','Alpha',1,0);

\echo '=== 6. a draw, submitted by either side ==='
do $$ declare g uuid; mid uuid; begin
  perform act_as('Foxtrot');
  select id into g from teams where name='Golf';
  mid := submit_league_result(g, 2, 2);
  perform act_as('Golf');
  perform confirm_match(mid);
  raise notice 'ok: draw recorded';
end $$;

\echo '=== 7. standings ==='
select rank, name, played, won, drawn, lost, goals_for, goals_against,
       goal_difference, points
  from standings order by rank;
