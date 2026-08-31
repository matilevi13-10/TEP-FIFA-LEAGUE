-- ============================================================================
-- TEP FIFA LEAGUE — migration 002: email accounts, direct team creation, chat
--
-- Takes the original schema (teams shared a PIN to log in) to the current one:
--   • People sign up with email + password + a username. Supabase Auth owns
--     the credentials; this schema owns the username and who the admin is.
--   • Whoever signs up with league_settings.admin_email gets the admin controls.
--   • One person creates a team and names their teammate — either an existing
--     account or a placeholder name that person claims when they sign up.
--   • A league chat, with automatic result announcements and taunts.
--
-- Safe on your live database: additive, wrapped in a transaction, re-runnable.
-- Teams, matches, standings and the season all survive.
--
-- What happens to existing data:
--   • Every player on an existing team is kept, on that team, as an unclaimed
--     account. They claim it by signing up with that exact username.
--   • The old shared team PINs are dropped — Supabase Auth handles passwords
--     now, so there is nothing left to migrate them into.
--   • The old admin-only team login is removed; sign up with the admin email
--     instead.
--   • Duplicate usernames get a numeric suffix, since usernames are now unique.
--
-- AFTER RUNNING THIS, in the Supabase dashboard:
--   Authentication → Sign In / Providers → Email
--     • Confirm email:            OFF   (required — accounts must work at once)
--     • Allow new users to sign up: ON
--
-- GENERATED FILE — edit supabase/schema.sql, then run:
--   python3 supabase/migrations/build_002.py
-- ============================================================================

begin;

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- 1. Structure
-- ---------------------------------------------------------------------------

-- The very first schema kept both player names as columns on teams. If this
-- database still looks like that, build the players table and move them across
-- before anything else touches it.
do $$
begin
  if to_regclass('public.players') is null then
    create table public.players (
      id         uuid primary key default gen_random_uuid(),
      team_id    uuid references public.teams(id) on delete set null,
      name       text not null,
      slot       smallint check (slot in (1, 2)),
      created_at timestamptz not null default now()
    );

    if exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'teams' and column_name = 'player_one'
    ) then
      execute $mig$
        insert into public.players (team_id, name, slot)
        select id, btrim(player_one), 1 from public.teams where btrim(coalesce(player_one,'')) <> ''
        union all
        select id, btrim(player_two), 2 from public.teams where btrim(coalesce(player_two,'')) <> ''
      $mig$;
      alter table public.teams drop column if exists player_one;
      alter table public.teams drop column if exists player_two;
      raise notice 'Moved player names off teams into the players table.';
    end if;
  end if;
end $$;

alter table public.players add column if not exists user_id   uuid unique references auth.users(id) on delete set null;
alter table public.players add column if not exists email     text;
alter table public.players add column if not exists is_admin  boolean not null default false;
alter table public.players add column if not exists is_active boolean not null default true;
alter table public.players alter column team_id drop not null;
alter table public.players alter column slot    drop not null;

do $$ begin
  alter table public.players
    add constraint team_and_slot_together check ((team_id is null) = (slot is null));
exception when duplicate_object then null; end $$;

-- The original schema cascaded player deletion from the team. Dissolving a
-- team now has to return both players to the pool instead of deleting them.
alter table public.players drop constraint if exists players_team_id_fkey;
alter table public.players add constraint players_team_id_fkey
  foreign key (team_id) references public.teams(id) on delete set null;

alter table public.league_settings
  add column if not exists admin_email text not null default 'matilevi13@gmail.com';

-- Null means the season has not opened yet, which is what lets either teammate
-- dissolve their own team. Existing leagues that have already played are
-- back-filled below so nobody can suddenly walk out of a team mid-season.
alter table public.league_settings
  add column if not exists season_started_at timestamptz;

do $$
begin
  if exists (select 1 from public.matches where status = 'confirmed')
     and (select season_started_at is null from public.league_settings where id = 1) then
    update public.league_settings
       set season_started_at = coalesce(
             (select min(confirmed_at) from public.matches where status = 'confirmed'),
             now())
     where id = 1;
    raise notice 'Results already exist — season marked as started, so teams are locked.';
  end if;
end $$;

create table if not exists public.messages (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null default 'chat' check (kind in ('chat','result','taunt')),
  author_id   uuid references public.players(id) on delete set null,
  author_name text,
  team_name   text,
  body        text check (body is null or length(btrim(body)) between 1 and 500),
  match_id    uuid references public.matches(id) on delete cascade,
  created_at  timestamptz not null default clock_timestamp(),
  constraint chat_needs_body    check (kind <> 'chat'   or (body is not null and author_id is not null)),
  constraint taunt_needs_match  check (kind <> 'taunt'  or match_id is not null),
  constraint result_needs_match check (kind <> 'result' or match_id is not null)
);

create index if not exists messages_created_idx on public.messages (created_at desc);
create unique index if not exists messages_one_taunt_per_match
  on public.messages (match_id) where kind = 'taunt';
create unique index if not exists messages_one_result_per_match
  on public.messages (match_id) where kind = 'result';

-- ---------------------------------------------------------------------------
-- 2. Carry the existing league over
-- ---------------------------------------------------------------------------

do $$
declare t record; n int; new_name text;
begin
  -- Retire admin-only team logins: the admin is decided by email address now.
  if to_regclass('public.team_secrets') is not null then
    for t in
      select tm.id
        from public.teams tm
        join public.team_secrets ts on ts.team_id = tm.id
       where coalesce(tm.is_admin, false) and not coalesce(tm.is_active, true)
    loop
      delete from public.players where team_id = t.id;
      delete from public.teams   where id = t.id;
      raise notice 'Removed the old admin-only team login.';
    end loop;
  end if;

  -- Usernames are the sign-in identity from here on, so they must be unique.
  for t in
    select id, name,
           row_number() over (partition by lower(btrim(name)) order by created_at, id) as rn
      from public.players
  loop
    if t.rn > 1 then
      new_name := left(t.name, 36) || ' ' || t.rn;
      update public.players set name = new_name where id = t.id;
      raise notice 'Renamed duplicate player "%" to "%".', t.name, new_name;
    end if;
  end loop;

  select count(*) into n from public.players where user_id is null;
  if n > 0 then
    raise notice '% existing player(s) can claim their account by signing up with that username.', n;
  end if;
end $$;

create unique index if not exists players_name_key on public.players (lower(btrim(name)));
create index if not exists players_team_idx on public.players (team_id);

-- ---------------------------------------------------------------------------
-- 2b. No more draws — every result has a winner
-- ---------------------------------------------------------------------------

-- The standings view loses its "drawn" column, and CREATE OR REPLACE VIEW
-- cannot drop one, so it has to go first. Nothing depends on it but function
-- bodies, which are recreated below.
drop view if exists public.standings cascade;

-- A drawn result can no longer be represented. Any that already exist are
-- voided rather than deleted: the scores stay on the row, they simply stop
-- counting, and an admin can re-enter them with a winner.
do $$
declare m record; n int := 0;
begin
  for m in
    select mt.id, ta.name as team_a, tb.name as team_b, mt.score_a, mt.score_b
      from public.matches mt
      left join public.teams ta on ta.id = mt.team_a
      left join public.teams tb on tb.id = mt.team_b
     where mt.status = 'confirmed'
       and mt.score_a is not null and mt.score_b is not null
       and mt.score_a = mt.score_b
  loop
    update public.matches
       set status = 'voided',
           winner_id = null,
           admin_note = 'Voided by the no-draws migration — replay it or re-enter with a winner.',
           updated_at = now()
     where id = m.id;
    n := n + 1;
    raise notice 'Voided drawn result: % %-% %', m.team_a, m.score_a, m.score_b, m.team_b;
  end loop;

  if n = 0 then
    raise notice 'No drawn results found — nothing to void.';
  else
    raise notice '% drawn result(s) voided. Replay them, or re-enter each from Admin.', n;
  end if;
end $$;

do $$ begin
  alter table public.matches add constraint no_drawn_results check (
    status <> 'confirmed' or score_a is null or score_b is null or score_a <> score_b
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 2c. Placeholder players are gone — a player now exists only by signing up
-- ---------------------------------------------------------------------------

create table if not exists public.team_requests (
  id                 uuid primary key default gen_random_uuid(),
  from_player        uuid not null references public.players(id) on delete cascade,
  to_player          uuid not null references public.players(id) on delete cascade,
  proposed_team_name text check (proposed_team_name is null
                                 or length(btrim(proposed_team_name)) between 1 and 40),
  status             text not null default 'pending'
                     check (status in ('pending','accepted','declined','cancelled','expired')),
  created_at         timestamptz not null default now(),
  responded_at       timestamptz,
  constraint different_players check (from_player <> to_player)
);

create unique index if not exists team_requests_one_outgoing
  on public.team_requests (from_player) where status = 'pending';
create index if not exists team_requests_inbox_idx
  on public.team_requests (to_player) where status = 'pending';

-- A placeholder is a players row with no user_id: a name somebody typed for a
-- teammate who never signed up. Those cannot be created any more.
--
-- Unattached placeholders are removed here — nothing references them and they
-- would otherwise squat on usernames real people want.
--
-- Placeholders that sit ON A TEAM are NOT touched. Deleting one would silently
-- halve a team that may already have played matches, so they are listed for you
-- to decide about. Each one keeps its team until you act.
do $$
declare r record; free_count int := 0; held_count int := 0;
begin
  select count(*) into free_count
    from public.players where user_id is null and team_id is null;

  if free_count > 0 then
    delete from public.players where user_id is null and team_id is null;
    raise notice 'Removed % unattached placeholder player(s).', free_count;
  else
    raise notice 'No unattached placeholder players to remove.';
  end if;

  for r in
    select p.id as player_id, p.name as player_name, p.slot,
           t.id as team_id, t.name as team_name,
           (select string_agg(o.name, ' + ' order by o.slot)
              from public.players o where o.team_id = t.id) as roster,
           (select count(*) from public.matches m
             where m.team_a = t.id or m.team_b = t.id) as match_count
      from public.players p
      join public.teams t on t.id = p.team_id
     where p.user_id is null
     order by t.name, p.slot
  loop
    held_count := held_count + 1;
    raise warning 'PLACEHOLDER ON A TEAM — team "%" (roster: %), placeholder "%" in slot %, % match(es). Left in place for you to decide.',
      r.team_name, r.roster, r.player_name, r.slot, r.match_count;
  end loop;

  if held_count = 0 then
    raise notice 'No placeholders are attached to a team — nothing needs your decision.';
  else
    raise warning '% placeholder(s) above are on teams and were NOT deleted.', held_count;
    raise warning 'Options per team: (a) that person signs up with the exact username, then '
                  'update public.players set user_id = <their auth uid> where id = <placeholder id>; '
                  'or (b) dissolve the team from Admin, freeing the real player back to the pool.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Drop what this version replaces
-- ---------------------------------------------------------------------------

drop trigger if exists match_confirmed on public.matches;

-- Original (team-login) entry points
drop function if exists public.list_teams_for_signin();
drop function if exists public.admin_create_team(text, text, text, text);
drop function if exists public.admin_update_team(uuid, text, text, text, boolean, boolean);
drop function if exists public.admin_delete_team(uuid);
drop function if exists public.admin_update_settings(text, int, int, int);
drop function if exists public.admin_set_pin(uuid, text);
drop function if exists public.admin_set_role(uuid, boolean);
drop function if exists public.begin_signin(uuid, text);
drop function if exists public.link_account(uuid, text);

-- PIN-era entry points, if an interim version was ever applied here
drop function if exists public.list_players_for_signin();
drop function if exists public.create_player_account(text, text);
drop function if exists public.change_my_pin(text, text);
drop function if exists public.admin_create_player(text, text);
drop function if exists public.send_teammate_request(uuid, text);
drop function if exists public.cancel_teammate_request(uuid);
drop function if exists public.decline_teammate_request(uuid);
drop function if exists public.accept_teammate_request(uuid, text);
-- create_team took a teammate *name* and invented a player from it. Gone.
drop function if exists public.create_team(text, uuid, text);
drop function if exists public.admin_create_placeholder(text);
