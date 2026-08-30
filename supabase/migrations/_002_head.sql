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
drop function if exists public.expire_requests_for(uuid);
drop table if exists public.team_requests;
