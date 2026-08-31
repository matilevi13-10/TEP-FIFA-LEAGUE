\set ON_ERROR_STOP on
\pset pager off

-- Mirrors the client exactly: signUp passes the username as user metadata (so
-- the trigger can use it), then claim_account reconciles.
create or replace function signup(p_username text, p_email text) returns uuid
language plpgsql as $$
declare uid uuid; begin
  insert into auth.users (email, raw_user_meta_data)
  values (lower(p_email), jsonb_build_object('username', p_username))
  returning id into uid;
  perform set_config('test.uid', uid::text, false);
  perform set_config('test.email', lower(p_email), false);
  return claim_account(p_username);
end $$;

-- The only way a team can come into existence: ask, then accept.
create or replace function pair(a text, b text, tname text) returns uuid
language plpgsql as $$
declare r uuid; begin
  perform act_as(a);
  r := send_teammate_request((select id from players where lower(name)=lower(b)), tname);
  perform act_as(b);
  return accept_teammate_request(r, null);
end $$;

create or replace function act_as_team(p_team text) returns void language plpgsql as $$
declare n text; begin
  select p.name into n from players p join teams t on t.id = p.team_id
   where t.name = p_team and p.user_id is not null order by p.slot limit 1;
  perform act_as(n);
end $$;

create or replace function play(w text, l text, ws int, ls int) returns void
language plpgsql as $$
declare mid uuid; lid uuid; begin
  perform act_as_team(w); select id into lid from teams where name = l;
  mid := submit_league_result(lid, ws, ls);
  perform act_as_team(l); perform confirm_match(mid);
end $$;

-- signUp with no metadata, to prove the trigger still produces a usable row.
create or replace function signup_bare(p_email text) returns uuid
language plpgsql as $$
declare uid uuid; begin
  insert into auth.users (email) values (lower(p_email)) returning id into uid;
  perform set_config('test.uid', uid::text, false);
  perform set_config('test.email', lower(p_email), false);
  return uid;
end $$;

-- Mirrors signInWithPassword: the session is just a uid + email claim.
create or replace function act_as(p_username text) returns void language plpgsql as $$
declare uid uuid; em text; begin
  select p.user_id, p.email into uid, em from players p where lower(p.name) = lower(p_username);
  perform set_config('test.uid', coalesce(uid::text, ''), false);
  perform set_config('test.email', coalesce(em, ''), false);
end $$;

create or replace function act_as_team(p_team text) returns void language plpgsql as $$
declare n text; begin
  select p.name into n from players p join teams t on t.id = p.team_id
   where t.name = p_team and p.slot = 1 and p.user_id is not null;
  if n is null then
    select p.name into n from players p join teams t on t.id = p.team_id
     where t.name = p_team and p.user_id is not null limit 1;
  end if;
  perform act_as(n);
end $$;

\echo '=== 1. sign up with a username; the admin address gets the controls ==='
select signup('Mati', 'matilevi13@gmail.com') is not null as created;
do $$ begin
  perform act_as('Mati');
  if not is_admin() then raise exception 'TEST FAILED: the admin address did not get admin'; end if;
  raise notice 'ok: matilevi13@gmail.com is admin automatically';
  if (select email from players where name='Mati') <> 'matilevi13@gmail.com' then
    raise exception 'TEST FAILED: email not stored on the account';
  end if;
  if (select team_id from players where name='Mati') is not null then
    raise exception 'TEST FAILED: new account should have no team';
  end if;
  raise notice 'ok: new account starts with no team';
end $$;

select signup('Nico','nico@example.com'), signup('Leo','leo@example.com'),
       signup('Juan','juan@example.com'), signup('Tom','tom@example.com'),
       signup('Ben','ben@example.com'),  signup('Sam','sam@example.com'),
       signup('Max','max@example.com');

do $$ begin
  perform act_as('Nico');
  if is_admin() then raise exception 'TEST FAILED: a normal account got admin'; end if;
  raise notice 'ok: everyone else is a normal account';
end $$;

\echo '=== 2. usernames are unique, case-insensitively ==='
do $$ declare uid uuid; begin
  insert into auth.users (email) values ('someone@example.com') returning id into uid;
  perform set_config('test.uid', uid::text, false);
  perform set_config('test.email', 'someone@example.com', false);
  begin
    perform claim_account('mati');
    raise exception 'TEST FAILED: duplicate username accepted';
  exception when sqlstate 'P0001' then raise notice 'ok: username collision rejected'; end;
  -- and a valid one still works for the same session
  perform claim_account('Someone');
  raise notice 'ok: a free username works';
end $$;

\echo '=== 3. a team is formed by request then accept ==='
do $$ declare t uuid; r uuid; begin
  perform act_as('Mati');
  r := send_teammate_request((select id from players where name='Nico'), 'Los Galácticos');

  -- Nothing exists until the other side agrees.
  if exists (select 1 from teams) then
    raise exception 'TEST FAILED: a request alone created a team';
  end if;
  raise notice 'ok: a request alone creates no team';

  begin
    perform accept_teammate_request(r, null);
    raise exception 'TEST FAILED: the sender accepted their own request';
  exception when sqlstate 'P0001' then raise notice 'ok: only the recipient can accept'; end;

  begin
    perform send_teammate_request((select id from players where name='Leo'), 'Other');
    raise exception 'TEST FAILED: a second outgoing request was allowed';
  exception when sqlstate 'P0001' then raise notice 'ok: one outgoing request at a time'; end;

  perform act_as('Nico');
  t := accept_teammate_request(r, null);

  if (select count(*) from players where team_id = t) <> 2 then
    raise exception 'TEST FAILED: team does not have two players';
  end if;
  if (select slot from players where name='Mati') <> 1
     or (select slot from players where name='Nico') <> 2 then
    raise exception 'TEST FAILED: slots wrong (requester should be 1)';
  end if;
  if (select name from teams where id = t) <> 'Los Galácticos' then
    raise exception 'TEST FAILED: proposed name not used';
  end if;
  raise notice 'ok: accepting created the team, both linked, slots 1 and 2';
end $$;

\echo '=== 4. teamed players are out of the market ==='
do $$ begin
  perform act_as('Mati');   -- now on Los Galácticos
  begin
    perform send_teammate_request((select id from players where name='Leo'), 'Another');
    raise exception 'TEST FAILED: a teamed player sent a request';
  exception when sqlstate 'P0001' then raise notice 'ok: teamed player cannot send requests'; end;

  perform act_as('Leo');
  begin
    perform send_teammate_request((select id from players where name='Nico'), 'Poachers');
    raise exception 'TEST FAILED: a request to a teamed player was allowed';
  exception when sqlstate 'P0001' then raise notice 'ok: cannot request a teamed player'; end;

  begin
    perform send_teammate_request((select id from players where name='Leo'), 'Myself');
    raise exception 'TEST FAILED: sent a request to themselves';
  exception when sqlstate 'P0001' then raise notice 'ok: cannot pick yourself'; end;
end $$;

\echo '=== 5. nothing can bring a player into existence but sign-up ==='
do $$ declare n_before int; n_after int; begin
  select count(*) into n_before from players;

  perform act_as('Leo');
  -- There is no function that takes a teammate *name*; only an id of somebody
  -- who already signed up. A name that belongs to nobody has no id to pass.
  begin
    perform send_teammate_request(gen_random_uuid(), 'Ghost Team');
    raise exception 'TEST FAILED: a request to a non-existent player succeeded';
  exception when sqlstate 'P0002' then raise notice 'ok: cannot request somebody who does not exist'; end;

  select count(*) into n_after from players;
  if n_after <> n_before then
    raise exception 'TEST FAILED: the player count changed (% -> %)', n_before, n_after;
  end if;
  raise notice 'ok: no player was invented';

  -- and the old placeholder entry points are gone for good
  if exists (select 1 from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
              where nsp.nspname='public'
                and p.proname in ('create_team','admin_create_placeholder')) then
    raise exception 'TEST FAILED: a placeholder-creating function still exists';
  end if;
  raise notice 'ok: create_team and admin_create_placeholder no longer exist';
end $$;

\echo '=== 6. team names are unique and required ==='
do $$ declare r uuid; begin
  perform act_as('Tom');
  begin
    perform send_teammate_request((select id from players where name='Ben'), 'los galácticos');
    raise exception 'TEST FAILED: duplicate team name accepted on the request';
  exception when sqlstate 'P0001' then raise notice 'ok: duplicate name rejected when proposing'; end;

  r := send_teammate_request((select id from players where name='Ben'), null);
  perform act_as('Ben');
  begin
    perform accept_teammate_request(r, 'LOS GALÁCTICOS');
    raise exception 'TEST FAILED: duplicate team name accepted on accept';
  exception when sqlstate 'P0001' then raise notice 'ok: duplicate name rejected when accepting'; end;
  begin
    perform accept_teammate_request(r, '   ');
    raise exception 'TEST FAILED: blank team name accepted';
  exception when sqlstate 'P0001' then raise notice 'ok: blank team name rejected'; end;
  perform accept_teammate_request(r, 'Route One');
  raise notice 'ok: accepted with a valid name';
end $$;

\echo '=== 7. fill out the league ==='
select signup('Ari','ari@example.com'), signup('Ivo','ivo@example.com'),
       signup('Gus','gus@example.com'), signup('Pep','pep@example.com'),
       signup('Kai','kai@example.com'), signup('Ozzy','ozzy@example.com'),
       signup('Ana','ana@example.com');
select pair('Leo','Juan','Tiki Taka');
select pair('Sam','Max','Catenaccio');
select pair('Someone','Ari','Gegenpress');
select pair('Ivo','Gus','Park The Bus');
select pair('Pep','Ana','Total Football');
select pair('Kai','Ozzy','Long Ball FC');
select t.name, (select count(*) from players p where p.team_id = t.id) as players from teams t order by t.name;

\echo '=== 8. a signed-in account with no profile repairs itself ==='
do $$ declare uid uuid; pid uuid; n_before int; begin

  -- An account that predates the trigger: it exists in auth with no profile.
  -- Deleting the trigger-created row reproduces exactly that state.
  insert into auth.users (email) values ('orphan@example.com') returning id into uid;
  delete from players where user_id = uid;
  perform set_config('test.uid', uid::text, false);
  perform set_config('test.email', 'orphan@example.com', false);

  if (select id from players where user_id = uid) is not null then
    raise exception 'TEST FAILED: fixture is wrong, profile already exists';
  end if;
  select count(*) into n_before from players;

  pid := ensure_account();
  if pid is null then raise exception 'TEST FAILED: ensure_account returned nothing'; end if;
  if (select name from players where id = pid) <> 'orphan' then
    raise exception 'TEST FAILED: username not derived from the email, got "%"',
      (select name from players where id = pid);
  end if;
  if (select count(*) from players) <> n_before + 1 then
    raise exception 'TEST FAILED: wrong number of rows created';
  end if;
  raise notice 'ok: orphaned login got a profile from its email';

  -- Idempotent: calling again must not create a second row.
  if ensure_account() <> pid then raise exception 'TEST FAILED: ensure_account was not idempotent'; end if;
  if (select count(*) from players) <> n_before + 1 then
    raise exception 'TEST FAILED: ensure_account created a duplicate';
  end if;
  raise notice 'ok: ensure_account is idempotent';
end $$;

do $$ declare uid uuid; begin
  -- A colliding local-part gets a suffix rather than failing.
  insert into auth.users (email) values ('orphan@other.com') returning id into uid;
  delete from players where user_id = uid;
  perform set_config('test.uid', uid::text, false);
  perform set_config('test.email', 'orphan@other.com', false);
  perform ensure_account();
  if (select name from players where user_id = uid) <> 'orphan 2' then
    raise exception 'TEST FAILED: collision not resolved, got "%"',
      (select name from players where user_id = uid);
  end if;
  raise notice 'ok: username collisions get a suffix';
end $$;

do $$ declare uid uuid; begin
  -- The admin address gets the controls even via this path.
  insert into auth.users (email) values ('admin2@example.com') returning id into uid;
  delete from players where user_id = uid;
  perform set_config('test.uid', uid::text, false);
  perform set_config('test.email', 'matilevi13@gmail.com', false);
  perform ensure_account();
  if not is_admin() then raise exception 'TEST FAILED: admin address did not get admin via ensure_account'; end if;
  raise notice 'ok: admin address recognised through ensure_account too';
  delete from players where user_id = uid;
  delete from auth.users where id = uid;
end $$;

\echo '=== 9. the auth trigger creates the profile before the client asks ==='
do $$ declare uid uuid; pid uuid; begin
  insert into auth.users (email, raw_user_meta_data)
  values ('trigger@example.com', jsonb_build_object('username', 'Triggered'))
  returning id into uid;

  -- No claim_account call at all — the trigger alone must have done it.
  select id into pid from players where user_id = uid;
  if pid is null then
    raise exception 'TEST FAILED: the trigger did not create a profile';
  end if;
  if (select name from players where id = pid) <> 'Triggered' then
    raise exception 'TEST FAILED: trigger ignored the metadata username, got "%"',
      (select name from players where id = pid);
  end if;
  raise notice 'ok: trigger creates the profile from sign-up metadata';
end $$;

do $$ declare uid uuid; begin
  -- No metadata at all: still gets a usable row, named from the email.
  select signup_bare('nometa@example.com') into uid;
  if (select name from players where user_id = uid) <> 'nometa' then
    raise exception 'TEST FAILED: no-metadata sign-up got name "%"',
      (select name from players where user_id = uid);
  end if;
  raise notice 'ok: sign-up without metadata still lands a profile';
end $$;

do $$ declare uid uuid; keep text; begin
  -- The admin address gets the flag straight from the trigger. Point the league
  -- at a spare address so this doesn't collide with Mati's account.
  select admin_email into keep from league_settings where id = 1;
  update league_settings set admin_email = 'boss@example.com' where id = 1;

  insert into auth.users (email, raw_user_meta_data)
  values ('boss@example.com', jsonb_build_object('username', 'TheAdmin'))
  returning id into uid;
  if not (select is_admin from players where user_id = uid) then
    raise exception 'TEST FAILED: admin address did not get the flag from the trigger';
  end if;
  raise notice 'ok: admin flag set by the trigger';

  delete from players where user_id = uid;
  delete from auth.users where id = uid;
  update league_settings set admin_email = keep where id = 1;
  perform sync_admin_flags();
end $$;

\echo '=== 10. cancel, decline, and auto-expiry ==='
select signup('Cando','cando@example.com'), signup('Declan','declan@example.com'),
       signup('Wanted','wanted@example.com'), signup('Rival','rival@example.com');

do $$ declare r uuid; begin
  perform act_as('Cando');
  r := send_teammate_request((select id from players where name='Declan'), 'Withdrawn');
  perform cancel_teammate_request(r);
  if (select status from team_requests where id=r) <> 'cancelled' then
    raise exception 'TEST FAILED: cancel did not stick';
  end if;
  raise notice 'ok: the sender can cancel';

  -- and cancelling frees them to ask again
  r := send_teammate_request((select id from players where name='Declan'), null);
  perform act_as('Declan');
  perform decline_teammate_request(r);
  if (select status from team_requests where id=r) <> 'declined' then
    raise exception 'TEST FAILED: decline did not stick';
  end if;
  if exists (select 1 from teams where name='Withdrawn') then
    raise exception 'TEST FAILED: a declined request still made a team';
  end if;
  raise notice 'ok: the recipient can decline';
end $$;

do $$ declare r1 uuid; r2 uuid; begin
  -- Cando and Rival both ask Wanted. Wanted accepts Cando, so Rival's request
  -- must expire rather than linger against a teamed player.
  perform act_as('Cando');
  r1 := send_teammate_request((select id from players where name='Wanted'), 'First Past');
  perform act_as('Rival');
  r2 := send_teammate_request((select id from players where name='Wanted'), 'Too Slow');
  perform act_as('Wanted');
  perform accept_teammate_request(r1, null);

  if (select status from team_requests where id=r2) <> 'expired' then
    raise exception 'TEST FAILED: the losing request is still "%"',
      (select status from team_requests where id=r2);
  end if;
  raise notice 'ok: competing requests auto-expire on accept';

  -- and the loser cannot force it through afterwards
  perform act_as('Wanted');
  begin
    perform accept_teammate_request(r2, 'Too Slow');
    raise exception 'TEST FAILED: an expired request was accepted';
  exception when sqlstate 'P0001' then raise notice 'ok: an expired request cannot be accepted'; end;
end $$;

\echo '=== 10b. either teammate can rename their own team ==='
do $$ begin
  perform act_as('Cando');            -- slot 1 of First Past
  perform rename_team('Renamed By One');
  if not exists (select 1 from teams where name='Renamed By One') then
    raise exception 'TEST FAILED: slot 1 could not rename';
  end if;
  raise notice 'ok: the requester can rename';

  perform act_as('Wanted');           -- slot 2 of the same team
  perform rename_team('Renamed By Two');
  if not exists (select 1 from teams where name='Renamed By Two') then
    raise exception 'TEST FAILED: slot 2 could not rename';
  end if;
  raise notice 'ok: the accepter can rename too';

  begin
    perform rename_team('Los Galácticos');
    raise exception 'TEST FAILED: renamed onto a taken name';
  exception when sqlstate 'P0001' then raise notice 'ok: rename respects uniqueness'; end;

  begin
    perform rename_team('   ');
    raise exception 'TEST FAILED: blank rename accepted';
  exception when sqlstate 'P0001' then raise notice 'ok: blank rename rejected'; end;

  -- somebody with no team has nothing to rename
  perform act_as('Declan');
  begin
    perform rename_team('Nice Try');
    raise exception 'TEST FAILED: a teamless player renamed something';
  exception when sqlstate 'P0001' then raise notice 'ok: teamless players cannot rename'; end;
end $$;

\echo '=== 11. a broken trigger must never block sign-up ==='
do $$ declare uid uuid; begin
  -- Force the inner call to fail, and prove the auth user is still created.
  alter table public.players add constraint tmp_break check (name <> 'Boom');
  insert into auth.users (email, raw_user_meta_data)
  values ('boom@example.com', jsonb_build_object('username', 'Boom'))
  returning id into uid;

  if uid is null or not exists (select 1 from auth.users where id = uid) then
    raise exception 'TEST FAILED: a failing trigger rolled back the auth user';
  end if;
  raise notice 'ok: sign-up survives a failing trigger';

  alter table public.players drop constraint tmp_break;

  -- ...and ensure_account repairs it on first load, which is the whole point.
  perform set_config('test.uid', uid::text, false);
  perform set_config('test.email', 'boom@example.com', false);
  perform ensure_account();
  if (select count(*) from players where user_id = uid) <> 1 then
    raise exception 'TEST FAILED: ensure_account did not repair the orphan';
  end if;
  raise notice 'ok: ensure_account repairs what the trigger missed';
end $$;

\echo '=== 12. username_available, and claim_account on a taken name ==='
do $$ begin
  if username_available('Mati') then
    raise exception 'TEST FAILED: a taken username reported available';
  end if;
  if not username_available('Nobody Has This') then
    raise exception 'TEST FAILED: a free username reported unavailable';
  end if;
  if username_available('   ') then
    raise exception 'TEST FAILED: blank reported available';
  end if;
  raise notice 'ok: username_available answers correctly';

  perform act_as('Nico');
  begin
    perform claim_account('Mati');
    raise exception 'TEST FAILED: claimed a username belonging to someone else';
  exception when sqlstate 'P0001' then raise notice 'ok: taken username rejected'; end;
end $$;

\echo '=== 13. no signed-in account can end up without a profile ==='
do $$ declare n int; begin
  select count(*) into n from auth.users u
   where not exists (select 1 from players p where p.user_id = u.id);
  if n <> 0 then
    raise exception 'TEST FAILED: % auth user(s) have no profile', n;
  end if;
  raise notice 'ok: every auth user has exactly one profile';
end $$;

\echo '=== 14. leaving a team before the season starts ==='
select signup('Quitter','quitter@example.com'), signup('Stranded','stranded@example.com'),
       signup('Hopeful','hopeful@example.com');

do $$ declare t uuid; r uuid; begin
  -- Hopeful asks Quitter, gets declined; that request must never come back.
  perform act_as('Hopeful');
  r := send_teammate_request((select id from players where name='Quitter'), 'Wishful');
  perform act_as('Quitter');
  perform decline_teammate_request(r);

  t := pair('Quitter','Stranded','Short Lived');
  if t is null then raise exception 'TEST FAILED: fixture team not formed'; end if;

  if season_has_started() then
    raise exception 'TEST FAILED: season reads as started with no results';
  end if;
  raise notice 'ok: pre-season while nothing has happened';

  -- Either member can go; here it is the one who accepted (slot 2).
  perform act_as('Stranded');
  perform leave_team();

  if exists (select 1 from teams where name='Short Lived') then
    raise exception 'TEST FAILED: the team survived';
  end if;
  raise notice 'ok: leaving dissolved the team';

  if (select count(*) from players
       where name in ('Quitter','Stranded') and team_id is null and slot is null) <> 2 then
    raise exception 'TEST FAILED: both players did not return to the pool';
  end if;
  raise notice 'ok: both players are back in the pool, unteamed';

  -- The declined request stays declined.
  if (select status from team_requests where id = r) <> 'declined' then
    raise exception 'TEST FAILED: an old request was resurrected as "%"',
      (select status from team_requests where id = r);
  end if;
  raise notice 'ok: old requests are not resurrected';

  -- The name is free again.
  perform act_as('Quitter');
  perform send_teammate_request((select id from players where name='Stranded'), 'Short Lived');
  perform act_as('Stranded');
  perform accept_teammate_request(
    (select id from team_requests where from_player=(select id from players where name='Quitter')
       and status='pending'), null);
  if not exists (select 1 from teams where name='Short Lived') then
    raise exception 'TEST FAILED: the freed name could not be reused';
  end if;
  raise notice 'ok: the team name was freed and reused';
end $$;

\echo '=== 14b. once the season starts, leaving is gone ==='
do $$ begin
  perform act_as('Mati');
  perform admin_set_season_started(true);
  if not season_has_started() then
    raise exception 'TEST FAILED: admin start did not register';
  end if;
  raise notice 'ok: admin can start the season';

  perform act_as('Quitter');
  begin
    perform leave_team();
    raise exception 'TEST FAILED: left a team after the season started';
  exception when sqlstate 'P0001' then raise notice 'ok: leaving blocked once started'; end;

  -- reopening is the admin's call too
  perform act_as('Mati');
  perform admin_set_season_started(false);
  if season_has_started() then
    raise exception 'TEST FAILED: could not reopen the pre-season';
  end if;
  raise notice 'ok: admin can reopen the pre-season';
end $$;

do $$ begin
  -- A confirmed result counts as started even if the admin never pressed start.
  if not season_has_started() then raise notice 'ok: still pre-season before any result'; end if;
  perform play('Los Galácticos','Tiki Taka', 2, 1);
  if not season_has_started() then
    raise exception 'TEST FAILED: a confirmed result did not start the season';
  end if;
  raise notice 'ok: a confirmed result starts the season on its own';

  perform act_as('Quitter');
  begin
    perform leave_team();
    raise exception 'TEST FAILED: left a team after a result was confirmed';
  exception when sqlstate 'P0001' then raise notice 'ok: leaving blocked by a played match'; end;
end $$;

do $$ begin
  -- Somebody with no team has nothing to leave.
  perform act_as('Hopeful');
  begin
    perform leave_team();
    raise exception 'TEST FAILED: a teamless player left something';
  exception when sqlstate 'P0001' then raise notice 'ok: teamless players cannot leave'; end;
end $$;
