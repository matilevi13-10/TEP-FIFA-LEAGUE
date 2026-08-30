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

-- ---------------------------------------------------------------------------
-- Identity helpers
-- ---------------------------------------------------------------------------

create or replace function public.current_player_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.players where user_id = auth.uid();
$$;

create or replace function public.current_team_id()
returns uuid language sql stable security definer set search_path = public as $$
  select team_id from public.players where user_id = auth.uid();
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select p.is_admin from public.players p where p.user_id = auth.uid()),
    false
  )
  or lower(btrim(coalesce(auth.jwt() ->> 'email', ''))) =
     (select lower(btrim(ls.admin_email)) from public.league_settings ls where ls.id = 1);
$$;

-- ---------------------------------------------------------------------------
-- Standings — the single source of truth for rank and playoff seeding.
-- Only confirmed league matches count.
-- ---------------------------------------------------------------------------

create or replace view public.standings with (security_invoker = on) as
with played as (
  select team_a as team_id, score_a as gf, score_b as ga
    from public.matches where phase = 'league' and status = 'confirmed'
  union all
  select team_b, score_b, score_a
    from public.matches where phase = 'league' and status = 'confirmed'
),
agg as (
  select
    t.id   as team_id,
    t.name,
    count(p.team_id)::int                                as played,
    (count(*) filter (where p.gf > p.ga))::int           as won,
    (count(*) filter (where p.gf < p.ga))::int           as lost,
    coalesce(sum(p.gf), 0)::int                          as goals_for,
    coalesce(sum(p.ga), 0)::int                          as goals_against,
    (count(*) filter (where p.gf > p.ga) * 3)::int       as points
  from public.teams t
  left join played p on p.team_id = t.id
  where t.is_active
  group by t.id, t.name
)
select
  agg.*,
  (goals_for - goals_against)::int as goal_difference,
  rank() over (
    order by points desc, (goals_for - goals_against) desc, goals_for desc, name asc
  )::int as rank
from agg;

-- ---------------------------------------------------------------------------
-- Row Level Security
--   Reads: every signed-in player sees the league — teams, players, requests,
--   matches, settings.
--   Writes: none directly. Everything goes through the RPCs below, which
--   enforce the rules server-side.
-- ---------------------------------------------------------------------------

alter table public.teams           enable row level security;
alter table public.players         enable row level security;
alter table public.messages        enable row level security;
alter table public.league_settings enable row level security;
alter table public.matches         enable row level security;

drop policy if exists teams_read on public.teams;
create policy teams_read on public.teams           for select to authenticated using (true);
drop policy if exists players_read on public.players;
create policy players_read on public.players         for select to authenticated using (true);
drop policy if exists settings_read on public.league_settings;
create policy settings_read on public.league_settings for select to authenticated using (true);
drop policy if exists matches_read on public.matches;
create policy matches_read on public.matches         for select to authenticated using (true);
drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages        for select to authenticated using (true);


-- ---------------------------------------------------------------------------
-- Accounts
--
-- Supabase Auth owns email and password. This layer owns the username, which
-- is the identity everyone actually sees, and works out who the admin is.
-- ---------------------------------------------------------------------------

-- Called once, straight after signUp, to attach a username to the new auth
-- user. If somebody already named this person as a teammate, the placeholder
-- row is claimed instead of creating a second one.
create or replace function public.claim_account(p_username text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  uid         uuid := auth.uid();
  my_email    text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  admin_email text;
  existing    public.players%rowtype;
  pid         uuid;
begin
  if uid is null then
    raise exception 'Not signed in.' using errcode = 'P0001';
  end if;
  if p_username is null or length(btrim(p_username)) < 1 or length(btrim(p_username)) > 40 then
    raise exception 'Pick a username between 1 and 40 characters.' using errcode = 'P0001';
  end if;

  -- Already set up (a repeated call, or a page reload mid sign-up).
  select id into pid from public.players where user_id = uid;
  if pid is not null then
    return pid;
  end if;

  select lower(btrim(ls.admin_email)) into admin_email from public.league_settings ls where ls.id = 1;

  select * into existing from public.players
   where lower(btrim(name)) = lower(btrim(p_username));

  if found then
    if existing.user_id is not null then
      raise exception 'The username "%" is taken. Pick another.', btrim(p_username)
        using errcode = 'P0001';
    end if;
    -- Claim the placeholder somebody created for them, team and all.
    update public.players
       set user_id = uid, email = my_email,
           name = btrim(p_username),
           is_admin = (my_email = admin_email)
     where id = existing.id
    returning id into pid;
  else
    insert into public.players (user_id, email, name, is_admin)
    values (uid, my_email, btrim(p_username), my_email = admin_email)
    returning id into pid;
  end if;

  return pid;
end;
$$;

-- Guarantees the signed-in user has a profile row, inventing a username from
-- their email if they somehow arrived without one (an account created before
-- this schema, or a sign-up interrupted between signUp and claim_account).
-- There is no such thing as a signed-in user with no profile.
create or replace function public.ensure_account()
returns uuid language plpgsql security definer set search_path = public as $$
declare
  uid         uuid := auth.uid();
  my_email    text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  admin_email text;
  base        text;
  candidate   text;
  n           int := 1;
  pid         uuid;
begin
  if uid is null then
    raise exception 'Not signed in.' using errcode = 'P0001';
  end if;

  select id into pid from public.players where user_id = uid;
  if pid is not null then
    -- Keep the email and admin flag current on every sign-in.
    select lower(btrim(ls.admin_email)) into admin_email
      from public.league_settings ls where ls.id = 1;
    update public.players
       set email = coalesce(nullif(my_email, ''), email),
           is_admin = (coalesce(nullif(my_email, ''), email) = admin_email)
     where id = pid;
    return pid;
  end if;

  select lower(btrim(ls.admin_email)) into admin_email
    from public.league_settings ls where ls.id = 1;

  -- Take the part before the @, fall back to "player".
  base := nullif(btrim(split_part(my_email, '@', 1)), '');
  base := left(coalesce(base, 'player'), 36);
  candidate := base;

  while exists (select 1 from public.players where lower(btrim(name)) = lower(candidate)) loop
    n := n + 1;
    candidate := base || ' ' || n;
  end loop;

  insert into public.players (user_id, email, name, is_admin)
  values (uid, nullif(my_email, ''), candidate, my_email = admin_email)
  returning id into pid;

  return pid;
end;
$$;

-- Keeps the admin flag honest if the admin address is ever changed, and after
-- the very first sign-up.
create or replace function public.sync_admin_flags()
returns void language plpgsql security definer set search_path = public as $$
declare admin_email text;
begin
  select lower(btrim(ls.admin_email)) into admin_email from public.league_settings ls where ls.id = 1;
  update public.players
     set is_admin = (lower(btrim(coalesce(email, ''))) = admin_email)
   where is_admin is distinct from (lower(btrim(coalesce(email, ''))) = admin_email);
end;
$$;

-- ---------------------------------------------------------------------------
-- Teams
--
-- One person creates the team and names the other half. The teammate is either
-- an existing account or a placeholder name they claim when they sign up.
-- ---------------------------------------------------------------------------

create or replace function public.create_team(
  p_name text, p_teammate_id uuid default null, p_teammate_name text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  me       public.players%rowtype;
  mate     public.players%rowtype;
  mate_id  uuid;
  team_name text := nullif(btrim(coalesce(p_name, '')), '');
  new_team uuid;
begin
  select * into me from public.players where user_id = auth.uid() for update;
  if not found then raise exception 'Not signed in.' using errcode = 'P0001'; end if;
  if me.team_id is not null then
    raise exception 'You are already on a team.' using errcode = 'P0001';
  end if;

  if team_name is null then
    raise exception 'Give the team a name.' using errcode = 'P0001';
  end if;
  if length(team_name) > 40 then
    raise exception 'Team names top out at 40 characters.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.teams where lower(btrim(name)) = lower(team_name)) then
    raise exception 'A team called "%" already exists.', team_name using errcode = 'P0001';
  end if;

  if p_teammate_id is not null then
    select * into mate from public.players where id = p_teammate_id for update;
    if not found then raise exception 'That player does not exist.' using errcode = 'P0002'; end if;
    if mate.id = me.id then
      raise exception 'Pick somebody other than yourself.' using errcode = 'P0001';
    end if;
    if mate.team_id is not null then
      raise exception '% is already on a team.', mate.name using errcode = 'P0001';
    end if;
    mate_id := mate.id;
  else
    if p_teammate_name is null or length(btrim(p_teammate_name)) = 0 then
      raise exception 'Name your teammate.' using errcode = 'P0001';
    end if;
    if length(btrim(p_teammate_name)) > 40 then
      raise exception 'Names top out at 40 characters.' using errcode = 'P0001';
    end if;
    if lower(btrim(p_teammate_name)) = lower(btrim(me.name)) then
      raise exception 'Pick somebody other than yourself.' using errcode = 'P0001';
    end if;

    select * into mate from public.players
     where lower(btrim(name)) = lower(btrim(p_teammate_name)) for update;

    if found then
      if mate.team_id is not null then
        raise exception '% is already on a team.', mate.name using errcode = 'P0001';
      end if;
      mate_id := mate.id;
    else
      -- A placeholder: they claim this row when they sign up under this name.
      insert into public.players (name) values (btrim(p_teammate_name))
      returning id into mate_id;
    end if;
  end if;

  insert into public.teams (name) values (team_name) returning id into new_team;
  update public.players set team_id = new_team, slot = 1 where id = me.id;
  update public.players set team_id = new_team, slot = 2 where id = mate_id;
  return new_team;
end;
$$;

-- ---------------------------------------------------------------------------
-- Match submission and confirmation
-- ---------------------------------------------------------------------------

create or replace function public.games_played(p_team uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.matches
   where phase = 'league' and status in ('confirmed','pending','disputed')
     and (team_a = p_team or team_b = p_team);
$$;

-- Records a league result. The winning team submits; there are no draws.
create or replace function public.submit_league_result(
  p_opponent uuid, p_my_score int, p_opp_score int
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  me     uuid := public.current_team_id();
  cfg    public.league_settings%rowtype;
  opp    public.teams%rowtype;
  new_id uuid;
begin
  if public.current_player_id() is null then
    raise exception 'Not signed in.' using errcode = 'P0001';
  end if;
  if me is null then
    raise exception 'You need a team before you can log a result.' using errcode = 'P0001';
  end if;
  if me = p_opponent then
    raise exception 'Pick an opponent other than your own team.' using errcode = 'P0001';
  end if;

  select * into cfg from public.league_settings where id = 1;
  if cfg.phase <> 'league' then
    raise exception 'The league phase is closed — playoffs have started.' using errcode = 'P0001';
  end if;

  select * into opp from public.teams where id = p_opponent;
  if not found or not opp.is_active then
    raise exception 'That opponent is not in the league.' using errcode = 'P0002';
  end if;

  if p_my_score is null or p_opp_score is null
     or p_my_score < 0 or p_opp_score < 0 or p_my_score > 99 or p_opp_score > 99 then
    raise exception 'Enter a valid score.' using errcode = 'P0001';
  end if;

  if p_my_score = p_opp_score then
    raise exception 'Games cannot end level — play it out until somebody wins.'
      using errcode = 'P0001';
  end if;
  if p_my_score < p_opp_score then
    raise exception 'The winning team submits the result. Ask % to send this one.', opp.name
      using errcode = 'P0001';
  end if;

  if public.games_played(me) >= cfg.games_per_team then
    raise exception 'You have already played all % of your games.', cfg.games_per_team
      using errcode = 'P0001';
  end if;
  if public.games_played(p_opponent) >= cfg.games_per_team then
    raise exception '% has already played all % of their games.', opp.name, cfg.games_per_team
      using errcode = 'P0001';
  end if;

  insert into public.matches (phase, team_a, team_b, score_a, score_b, status, submitted_by)
  values ('league', me, p_opponent, p_my_score, p_opp_score, 'pending', me)
  returning id into new_id;
  return new_id;
end;
$$;

-- Records a playoff result into an existing bracket slot.
create or replace function public.submit_playoff_result(
  p_match_id uuid, p_my_score int, p_opp_score int
) returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_team_id(); m public.matches%rowtype;
begin
  if me is null then
    raise exception 'You need a team before you can log a result.' using errcode = 'P0001';
  end if;

  select * into m from public.matches where id = p_match_id for update;
  if not found or m.phase <> 'playoff' then
    raise exception 'That playoff match does not exist.' using errcode = 'P0002';
  end if;
  if m.team_a is null or m.team_b is null then
    raise exception 'This matchup is still waiting on an earlier round.' using errcode = 'P0001';
  end if;
  if me not in (m.team_a, m.team_b) then
    raise exception 'You are not in this matchup.' using errcode = 'P0001';
  end if;
  if m.status not in ('scheduled','disputed') then
    raise exception 'This match already has a result submitted.' using errcode = 'P0001';
  end if;
  if p_my_score is null or p_opp_score is null
     or p_my_score < 0 or p_opp_score < 0 or p_my_score > 99 or p_opp_score > 99 then
    raise exception 'Enter a valid score.' using errcode = 'P0001';
  end if;
  if p_my_score = p_opp_score then
    raise exception 'Games cannot end level — play it out until somebody wins.'
      using errcode = 'P0001';
  end if;
  if p_my_score < p_opp_score then
    raise exception 'The winning team submits the result.' using errcode = 'P0001';
  end if;

  update public.matches
     set score_a      = case when me = team_a then p_my_score else p_opp_score end,
         score_b      = case when me = team_a then p_opp_score else p_my_score end,
         status       = 'pending',
         submitted_by = me,
         updated_at   = now()
   where id = p_match_id;
  return p_match_id;
end;
$$;

-- The opposing team approves. Nothing counts until this runs.
create or replace function public.confirm_match(p_match_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_team_id(); m public.matches%rowtype;
begin
  select * into m from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found.' using errcode = 'P0002'; end if;
  if m.status <> 'pending' then
    raise exception 'This match is no longer waiting on you.' using errcode = 'P0001';
  end if;
  if me is null or me not in (m.team_a, m.team_b) then
    raise exception 'You are not in this match.' using errcode = 'P0001';
  end if;
  if me = m.submitted_by then
    raise exception 'Your opponent has to confirm this one.' using errcode = 'P0001';
  end if;

  update public.matches
     set status       = 'confirmed',
         confirmed_by = me,
         confirmed_at = now(),
         winner_id    = case when score_a > score_b then team_a else team_b end,
         updated_at   = now()
   where id = p_match_id;
end;
$$;

create or replace function public.dispute_match(p_match_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_team_id(); m public.matches%rowtype;
begin
  select * into m from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found.' using errcode = 'P0002'; end if;
  if m.status <> 'pending' then
    raise exception 'This match is no longer waiting on you.' using errcode = 'P0001';
  end if;
  if me is null or me not in (m.team_a, m.team_b) or me = m.submitted_by then
    raise exception 'You cannot dispute this match.' using errcode = 'P0001';
  end if;

  update public.matches set status = 'disputed', updated_at = now() where id = p_match_id;
end;
$$;

-- Lets the submitting team take back its own pending result (mistyped score).
create or replace function public.cancel_submission(p_match_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_team_id(); m public.matches%rowtype;
begin
  select * into m from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found.' using errcode = 'P0002'; end if;
  if me is null or me <> m.submitted_by then
    raise exception 'Only the team that submitted this can take it back.' using errcode = 'P0001';
  end if;
  if m.status <> 'pending' then
    raise exception 'This result is already settled.' using errcode = 'P0001';
  end if;

  if m.phase = 'league' then
    delete from public.matches where id = p_match_id;
  else
    update public.matches
       set status = 'scheduled', score_a = null, score_b = null,
           submitted_by = null, updated_at = now()
     where id = p_match_id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Bracket progression
-- ---------------------------------------------------------------------------

-- Advances a confirmed playoff winner into its parent slot, or crowns the
-- champion if the match was the final.
create or replace function public.push_winner(p_match_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m public.matches%rowtype; par public.matches%rowtype; w uuid; wseed int;
begin
  select * into m from public.matches where id = p_match_id;
  if not found or m.phase <> 'playoff' or m.winner_id is null then return; end if;

  w := m.winner_id;
  wseed := case when w = m.team_a then m.seed_a else m.seed_b end;

  select * into par from public.matches
   where phase = 'playoff' and round = m.round + 1 and slot = m.slot / 2;

  if not found then
    update public.league_settings
       set champion_team_id = w, phase = 'complete', updated_at = now() where id = 1;
  elsif m.slot % 2 = 0 then
    update public.matches set team_a = w, seed_a = wseed, updated_at = now() where id = par.id;
  else
    update public.matches set team_b = w, seed_b = wseed, updated_at = now() where id = par.id;
  end if;
end;
$$;

-- Wipes every downstream slot that descended from a match, used when an admin
-- voids or rewrites a result that had already advanced somebody.
create or replace function public.clear_from(p_round int, p_slot int)
returns void language plpgsql security definer set search_path = public as $$
declare r int := p_round; s int := p_slot; par public.matches%rowtype;
begin
  loop
    select * into par from public.matches
     where phase = 'playoff' and round = r + 1 and slot = s / 2;

    if not found then
      update public.league_settings
         set champion_team_id = null,
             phase = case when phase = 'complete' then 'playoffs' else phase end,
             updated_at = now()
       where id = 1;
      return;
    end if;

    update public.matches
       set team_a  = case when s % 2 = 0 then null else team_a end,
           seed_a  = case when s % 2 = 0 then null else seed_a end,
           team_b  = case when s % 2 = 1 then null else team_b end,
           seed_b  = case when s % 2 = 1 then null else seed_b end,
           score_a = null, score_b = null, winner_id = null,
           status  = 'scheduled', submitted_by = null,
           confirmed_by = null, confirmed_at = null, updated_at = now()
     where id = par.id;

    r := par.round; s := par.slot;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- League chat
-- ---------------------------------------------------------------------------

-- Writes (or rewrites) the automatic result line for a match.
create or replace function public.post_result_message(p_match_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m public.matches%rowtype; a text; b text; winner text;
begin
  select * into m from public.matches where id = p_match_id;
  if not found or m.status <> 'confirmed' then return; end if;

  select name into a from public.teams where id = m.team_a;
  select name into b from public.teams where id = m.team_b;
  winner := case when m.winner_id = m.team_a then a else b end;

  insert into public.messages (kind, body, team_name, match_id)
  values ('result',
          coalesce(a, 'Unknown') || ' ' || m.score_a || '–' || m.score_b || ' ' || coalesce(b, 'Unknown'),
          winner, m.id)
  on conflict (match_id) where kind = 'result'
  do update set body = excluded.body, team_name = excluded.team_name;
end;
$$;

-- Confirming a match advances the bracket and announces the score. A result
-- that is later voided takes its announcement (and any taunt) with it.
create or replace function public.on_match_confirmed()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'confirmed'
     and (old.status is distinct from 'confirmed'
          or old.score_a is distinct from new.score_a
          or old.score_b is distinct from new.score_b) then
    if new.phase = 'playoff' and old.status is distinct from 'confirmed' then
      perform public.push_winner(new.id);
    end if;
    perform public.post_result_message(new.id);
  end if;

  if old.status = 'confirmed' and new.status <> 'confirmed' then
    delete from public.messages where match_id = new.id and kind in ('result','taunt');
  end if;

  return new;
end;
$$;

drop trigger if exists match_confirmed on public.matches;
create trigger match_confirmed after update on public.matches
  for each row execute function public.on_match_confirmed();

-- Anyone signed in can talk. Name and team are copied in so the line still
-- reads correctly later.
create or replace function public.post_message(p_body text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me public.players%rowtype; tname text; new_id uuid;
begin
  select * into me from public.players where user_id = auth.uid();
  if not found then raise exception 'Not signed in.' using errcode = 'P0001'; end if;
  if p_body is null or length(btrim(p_body)) = 0 then
    raise exception 'Say something first.' using errcode = 'P0001';
  end if;
  if length(btrim(p_body)) > 500 then
    raise exception 'Keep it under 500 characters.' using errcode = 'P0001';
  end if;

  select name into tname from public.teams where id = me.team_id;

  insert into public.messages (kind, author_id, author_name, team_name, body)
  values ('chat', me.id, me.name, tname, btrim(p_body))
  returning id into new_id;
  return new_id;
end;
$$;

-- The mic drop. Only the winning team, only once per match.
create or replace function public.post_taunt(p_match_id uuid, p_body text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me public.players%rowtype; m public.matches%rowtype; tname text; new_id uuid;
begin
  select * into me from public.players where user_id = auth.uid();
  if not found then raise exception 'Not signed in.' using errcode = 'P0001'; end if;
  if me.team_id is null then
    raise exception 'You are not on a team.' using errcode = 'P0001';
  end if;

  select * into m from public.matches where id = p_match_id;
  if not found then raise exception 'Match not found.' using errcode = 'P0002'; end if;
  if m.status <> 'confirmed' then
    raise exception 'That result is not confirmed yet.' using errcode = 'P0001';
  end if;
  if m.winner_id is null then
    raise exception 'Nobody won that one.' using errcode = 'P0001';
  end if;
  if m.winner_id <> me.team_id then
    raise exception 'Only the winning team gets to taunt.' using errcode = 'P0001';
  end if;
  if p_body is null or length(btrim(p_body)) = 0 then
    raise exception 'Say something first.' using errcode = 'P0001';
  end if;
  if length(btrim(p_body)) > 280 then
    raise exception 'Keep the taunt under 280 characters.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.messages where match_id = p_match_id and kind = 'taunt') then
    raise exception 'Your team already taunted this one.' using errcode = 'P0001';
  end if;

  select name into tname from public.teams where id = me.team_id;

  insert into public.messages (kind, author_id, author_name, team_name, body, match_id)
  values ('taunt', me.id, me.name, tname, btrim(p_body), p_match_id)
  returning id into new_id;
  return new_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Admin
-- ---------------------------------------------------------------------------

create or replace function public.assert_admin() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'Admins only.' using errcode = 'P0001';
  end if;
end;
$$;

-- Creates a placeholder for somebody who has not signed up yet. They claim it
-- by signing up with this exact username. Passwords are Supabase Auth's job, so
-- there is nothing to set here.
create or replace function public.admin_create_placeholder(p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  perform public.assert_admin();
  if p_name is null or length(btrim(p_name)) < 1 or length(btrim(p_name)) > 40 then
    raise exception 'Pick a name between 1 and 40 characters.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.players where lower(btrim(name)) = lower(btrim(p_name))) then
    raise exception 'A player called "%" already exists.', btrim(p_name) using errcode = 'P0001';
  end if;
  insert into public.players (name) values (btrim(p_name)) returning id into new_id;
  return new_id;
end;
$$;

create or replace function public.admin_rename_player(p_player_id uuid, p_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if exists (select 1 from public.players
              where lower(btrim(name)) = lower(btrim(p_name)) and id <> p_player_id) then
    raise exception 'A player called "%" already exists.', btrim(p_name) using errcode = 'P0001';
  end if;
  update public.players set name = btrim(p_name) where id = p_player_id;
end;
$$;

create or replace function public.admin_delete_player(p_player_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if (select team_id from public.players where id = p_player_id) is not null then
    raise exception 'Dissolve their team first.' using errcode = 'P0001';
  end if;
  delete from public.players where id = p_player_id;
end;
$$;

-- Fallback pairing, for when two players cannot sort it out between themselves.
create or replace function public.admin_create_team(
  p_name text, p_player_a uuid, p_player_b uuid
) returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid; a public.players%rowtype; b public.players%rowtype;
begin
  perform public.assert_admin();
  if p_player_a = p_player_b then
    raise exception 'A team needs two different players.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.teams where lower(btrim(name)) = lower(btrim(p_name))) then
    raise exception 'A team called "%" already exists.', btrim(p_name) using errcode = 'P0001';
  end if;

  select * into a from public.players where id = p_player_a for update;
  select * into b from public.players where id = p_player_b for update;
  if a.id is null or b.id is null then
    raise exception 'Player not found.' using errcode = 'P0002';
  end if;
  if a.team_id is not null then
    raise exception '% is already on a team.', a.name using errcode = 'P0001';
  end if;
  if b.team_id is not null then
    raise exception '% is already on a team.', b.name using errcode = 'P0001';
  end if;

  insert into public.teams (name) values (btrim(p_name)) returning id into new_id;
  update public.players set team_id = new_id, slot = 1 where id = a.id;
  update public.players set team_id = new_id, slot = 2 where id = b.id;
  return new_id;
end;
$$;

create or replace function public.admin_update_team(
  p_team_id uuid, p_name text, p_is_active boolean, p_paid boolean
) returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if exists (select 1 from public.teams
              where lower(btrim(name)) = lower(btrim(p_name)) and id <> p_team_id) then
    raise exception 'A team called "%" already exists.', btrim(p_name) using errcode = 'P0001';
  end if;
  update public.teams
     set name = btrim(p_name), is_active = p_is_active, paid = p_paid
   where id = p_team_id;
end;
$$;

-- Breaks a team up and puts both players back in the pool. Their matches go
-- with it, so this is league-phase only.
create or replace function public.admin_dissolve_team(p_team_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if (select phase from public.league_settings where id = 1) <> 'league' then
    raise exception 'Teams cannot be broken up once the playoffs have started.' using errcode = 'P0001';
  end if;
  update public.players set team_id = null, slot = null where team_id = p_team_id;
  delete from public.matches where team_a = p_team_id or team_b = p_team_id;
  delete from public.teams where id = p_team_id;
end;
$$;

create or replace function public.admin_delete_message(p_message_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  delete from public.messages where id = p_message_id;
end;
$$;

create or replace function public.admin_update_settings(
  p_season_name text, p_games_per_team int, p_buy_in_cents int, p_playoff_size int,
  p_admin_email text default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_games_per_team < 1 or p_games_per_team > 200 then
    raise exception 'Games per team has to be between 1 and 200.' using errcode = 'P0001';
  end if;
  if p_playoff_size is not null and p_playoff_size not in (4, 8, 16) then
    raise exception 'Playoffs must be 4, 8 or 16 teams.' using errcode = 'P0001';
  end if;
  update public.league_settings
     set season_name = btrim(p_season_name), games_per_team = p_games_per_team,
         buy_in_cents = p_buy_in_cents, playoff_size = p_playoff_size,
         admin_email = coalesce(nullif(btrim(p_admin_email), ''), admin_email),
         updated_at = now()
   where id = 1;
  perform public.sync_admin_flags();
end;
$$;

-- Locks the league and builds the whole single-elimination bracket in one shot.
create or replace function public.admin_start_playoffs(p_size int)
returns void language plpgsql security definer set search_path = public as $$
declare
  cfg          public.league_settings%rowtype;
  qualifiers   uuid[];
  order_seeds  int[];
  total_rounds int;
  active_count int;
  i int; r int; s int;
begin
  perform public.assert_admin();
  select * into cfg from public.league_settings where id = 1;
  if cfg.phase <> 'league' then
    raise exception 'The playoffs have already started.' using errcode = 'P0001';
  end if;
  if p_size not in (4, 8, 16) then
    raise exception 'Playoffs must be 4, 8 or 16 teams.' using errcode = 'P0001';
  end if;

  select count(*) into active_count from public.teams where is_active;
  if active_count < p_size then
    raise exception 'Need at least % teams for a %-team bracket — there are %.',
      p_size, p_size, active_count using errcode = 'P0001';
  end if;

  -- Standard bracket order, so the top two seeds can only meet in the final.
  order_seeds := case p_size
    when 4  then array[1,4,2,3]
    when 8  then array[1,8,4,5,2,7,3,6]
    else         array[1,16,8,9,4,13,5,12,2,15,7,10,3,14,6,11]
  end;

  select array_agg(team_id order by rank) into qualifiers
    from (select team_id, rank from public.standings order by rank limit p_size) q;

  -- Anything still awaiting confirmation can no longer affect seeding.
  update public.matches
     set status = 'voided', admin_note = 'Voided automatically when the playoffs started.',
         updated_at = now()
   where phase = 'league' and status in ('pending','disputed');

  delete from public.matches where phase = 'playoff';

  total_rounds := (log(2, p_size::numeric))::int;

  -- Round 1 gets real teams; later rounds are empty slots the trigger fills in.
  for i in 0 .. (p_size / 2 - 1) loop
    insert into public.matches (phase, round, slot, team_a, team_b, seed_a, seed_b, status)
    values ('playoff', 1, i,
            qualifiers[order_seeds[i * 2 + 1]], qualifiers[order_seeds[i * 2 + 2]],
            order_seeds[i * 2 + 1], order_seeds[i * 2 + 2], 'scheduled');
  end loop;

  for r in 2 .. total_rounds loop
    for s in 0 .. (p_size / (2 ^ r)::int - 1) loop
      insert into public.matches (phase, round, slot, status)
      values ('playoff', r, s, 'scheduled');
    end loop;
  end loop;

  update public.league_settings
     set phase = 'playoffs', playoff_size = p_size,
         playoffs_started_at = now(), champion_team_id = null, updated_at = now()
   where id = 1;
end;
$$;

-- Escape hatch: tear the bracket down and reopen the league phase.
create or replace function public.admin_reset_playoffs()
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  delete from public.matches where phase = 'playoff';
  update public.league_settings
     set phase = 'league', champion_team_id = null,
         playoffs_started_at = null, updated_at = now()
   where id = 1;
end;
$$;

-- Settles a dispute (or fixes a typo) by writing the score the admin decides on.
create or replace function public.admin_resolve_match(
  p_match_id uuid, p_score_a int, p_score_b int, p_note text default null
) returns void language plpgsql security definer set search_path = public as $$
declare m public.matches%rowtype;
begin
  perform public.assert_admin();
  select * into m from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found.' using errcode = 'P0002'; end if;
  if p_score_a is null or p_score_b is null
     or p_score_a < 0 or p_score_b < 0 or p_score_a > 99 or p_score_b > 99 then
    raise exception 'Enter a valid score.' using errcode = 'P0001';
  end if;
  if p_score_a = p_score_b then
    raise exception 'Games cannot end level — somebody has to win.' using errcode = 'P0001';
  end if;

  if m.phase = 'playoff' and m.status = 'confirmed' then
    perform public.clear_from(m.round, m.slot);
  end if;

  update public.matches
     set score_a = p_score_a, score_b = p_score_b, status = 'confirmed',
         winner_id = case when p_score_a > p_score_b then team_a else team_b end,
         confirmed_at = now(), admin_note = p_note, updated_at = now()
   where id = p_match_id;

  if m.phase = 'playoff' then perform public.push_winner(p_match_id); end if;
end;
$$;

create or replace function public.admin_void_match(p_match_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare m public.matches%rowtype;
begin
  perform public.assert_admin();
  select * into m from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found.' using errcode = 'P0002'; end if;

  if m.phase = 'playoff' then
    if m.status = 'confirmed' then perform public.clear_from(m.round, m.slot); end if;
    update public.matches
       set status = 'scheduled', score_a = null, score_b = null, winner_id = null,
           submitted_by = null, confirmed_by = null, confirmed_at = null,
           admin_note = p_note, updated_at = now()
     where id = p_match_id;
  else
    update public.matches
       set status = 'voided', winner_id = null, admin_note = p_note, updated_at = now()
     where id = p_match_id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants — the client may only reach the RPCs above, never a raw write.
-- ---------------------------------------------------------------------------

grant usage on schema public to anon, authenticated;
grant select on public.teams, public.players, public.league_settings,
                public.matches, public.standings, public.messages
  to authenticated;

do $$
declare fn text;
begin
  for fn in
    select p.oid::regprocedure::text
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', fn);
  end loop;
end;
$$;

grant execute on function
  public.claim_account(text),
  public.ensure_account(),
  public.current_player_id(),
  public.current_team_id(),
  public.is_admin(),
  public.create_team(text, uuid, text),
  public.submit_league_result(uuid, int, int),
  public.submit_playoff_result(uuid, int, int),
  public.confirm_match(uuid),
  public.dispute_match(uuid),
  public.cancel_submission(uuid),
  public.admin_create_placeholder(text),
  public.admin_rename_player(uuid, text),
  public.admin_delete_player(uuid),
  public.admin_create_team(text, uuid, uuid),
  public.admin_update_team(uuid, text, boolean, boolean),
  public.admin_dissolve_team(uuid),
  public.admin_update_settings(text, int, int, int, text),
  public.admin_start_playoffs(int),
  public.admin_reset_playoffs(),
  public.admin_resolve_match(uuid, int, int, text),
  public.admin_void_match(uuid, text),
  public.post_message(text),
  public.post_taunt(uuid, text),
  public.admin_delete_message(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Realtime — every phone re-renders the moment anything lands.
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['matches','teams','players','league_settings','messages'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Retire the shared-PIN plumbing, now that Supabase Auth owns credentials
-- ---------------------------------------------------------------------------

drop table if exists public.team_secrets;
drop table if exists public.player_secrets;
alter table public.teams drop column if exists user_id;
alter table public.teams drop column if exists is_admin;

commit;

do $$
declare who text;
begin
  select admin_email into who from public.league_settings where id = 1;
  raise notice '=================================================';
  raise notice ' Migration complete.';
  raise notice ' Sign up with % to get the admin controls.', who;
  raise notice ' Keep "Confirm email" OFF in Supabase Auth.';
  raise notice '=================================================';
end $$;
