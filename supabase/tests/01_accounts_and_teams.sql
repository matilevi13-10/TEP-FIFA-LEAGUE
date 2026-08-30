\set ON_ERROR_STOP on
\pset pager off

-- Mirrors the client: supabase.auth.signUp(email, password) → claim_account(username).
create or replace function signup(p_username text, p_email text) returns uuid
language plpgsql as $$
declare uid uuid; begin
  insert into auth.users (email) values (lower(p_email)) returning id into uid;
  perform set_config('test.uid', uid::text, false);
  perform set_config('test.email', lower(p_email), false);
  return claim_account(p_username);
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

\echo '=== 3. create a team by naming an existing user ==='
do $$ declare t uuid; begin
  perform act_as('Mati');
  t := create_team('Los Galácticos', (select id from players where name='Nico'), null);
  if (select count(*) from players where team_id = t) <> 2 then
    raise exception 'TEST FAILED: team does not have two players';
  end if;
  if (select slot from players where name='Mati') <> 1
     or (select slot from players where name='Nico') <> 2 then
    raise exception 'TEST FAILED: slots wrong';
  end if;
  raise notice 'ok: team created with an existing user';
end $$;

\echo '=== 4. one team per person ==='
do $$ begin
  perform act_as('Mati');
  begin
    perform create_team('Second Team', (select id from players where name='Leo'), null);
    raise exception 'TEST FAILED: created a second team';
  exception when sqlstate 'P0001' then raise notice 'ok: creator cannot be on two teams'; end;

  perform act_as('Leo');
  begin
    perform create_team('Poachers', (select id from players where name='Nico'), null);
    raise exception 'TEST FAILED: recruited an already-teamed player';
  exception when sqlstate 'P0001' then raise notice 'ok: cannot recruit a teamed player'; end;

  begin
    perform create_team('Myself', null, 'Leo');
    raise exception 'TEST FAILED: teamed up with themselves';
  exception when sqlstate 'P0001' then raise notice 'ok: cannot pick yourself'; end;
end $$;

\echo '=== 5. a placeholder teammate, claimed later at sign-up ==='
do $$ declare t uuid; ph uuid; begin
  perform act_as('Leo');
  t := create_team('Tiki Taka', null, 'Rui');
  select id into ph from players where lower(name) = 'rui';
  if ph is null then raise exception 'TEST FAILED: placeholder was not created'; end if;
  if (select user_id from players where id = ph) is not null then
    raise exception 'TEST FAILED: placeholder should have no account yet';
  end if;
  if (select team_id from players where id = ph) <> t then
    raise exception 'TEST FAILED: placeholder is not on the team';
  end if;
  raise notice 'ok: placeholder created and placed on the team';
end $$;

do $$ declare ph uuid; begin
  select id into ph from players where lower(name) = 'rui';
  perform signup('Rui', 'rui@example.com');
  if (select id from players where lower(name)='rui') <> ph then
    raise exception 'TEST FAILED: sign-up made a second row instead of claiming';
  end if;
  if (select user_id from players where id = ph) is null then
    raise exception 'TEST FAILED: placeholder was not claimed';
  end if;
  if (select name from teams where id = (select team_id from players where id = ph)) <> 'Tiki Taka' then
    raise exception 'TEST FAILED: claimed player lost their team';
  end if;
  if (select count(*) from players where lower(name)='rui') <> 1 then
    raise exception 'TEST FAILED: duplicate player rows for the same name';
  end if;
  raise notice 'ok: sign-up claimed the placeholder, team intact';
end $$;

\echo '=== 6. team names are unique and required ==='
do $$ begin
  perform act_as('Tom');
  begin
    perform create_team('los galácticos', null, 'Someone New');
    raise exception 'TEST FAILED: duplicate team name accepted';
  exception when sqlstate 'P0001' then raise notice 'ok: duplicate team name rejected'; end;
  begin
    perform create_team('  ', null, 'Another');
    raise exception 'TEST FAILED: blank team name accepted';
  exception when sqlstate 'P0001' then raise notice 'ok: blank team name rejected'; end;
end $$;

\echo '=== 7. fill out the league ==='
do $$ begin
  perform act_as('Tom'); perform create_team('Route One', (select id from players where name='Ben'), null);
  perform act_as('Sam'); perform create_team('Catenaccio', (select id from players where name='Max'), null);
  perform act_as('Someone'); perform create_team('Gegenpress', null, 'Ari');
end $$;
select signup('Ari','ari@example.com');
select signup('Ivo','ivo@example.com'), signup('Gus','gus@example.com'),
       signup('Pep','pep@example.com'), signup('Kai','kai@example.com'),
       signup('Ozzy','ozzy@example.com'), signup('Ana','ana@example.com');
do $$ begin
  perform act_as('Ivo'); perform create_team('Park The Bus', (select id from players where name='Gus'), null);
  perform act_as('Pep'); perform create_team('Total Football', (select id from players where name='Ana'), null);
  perform act_as('Kai'); perform create_team('Long Ball FC', (select id from players where name='Ozzy'), null);
end $$;
select t.name, (select count(*) from players p where p.team_id = t.id) as players from teams t order by t.name;
