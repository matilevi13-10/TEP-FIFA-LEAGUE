-- ============================================================================
-- TEP FIFA LEAGUE — full schema (v2: player accounts + team formation)
--
-- Fresh install only. Run this in the Supabase SQL Editor on an empty project;
-- it drops and recreates everything it owns.
--
-- Already running v1 (team logins)? Do NOT run this — it would wipe your data.
-- Run supabase/migrations/002_player_accounts.sql instead.
--
-- Model: a player is the login. Players start unassigned in the pool, pair up
-- by mutual consent into a team of exactly two, and the team is what plays
-- matches and appears in the table.
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Teardown (idempotent re-runs)
-- ---------------------------------------------------------------------------
drop view   if exists public.standings cascade;
drop table  if exists public.team_requests cascade;
drop table  if exists public.messages cascade;
drop table  if exists public.matches cascade;
drop table  if exists public.team_secrets cascade;
drop table  if exists public.players cascade;
drop table  if exists public.league_settings cascade;
drop table  if exists public.teams cascade;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.teams (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique check (length(btrim(name)) between 1 and 40),
  is_active  boolean not null default true,
  paid       boolean not null default false,
  created_at timestamptz not null default now()
);

-- A player is the account: one row per person, created only when that person
-- signs themselves up. Nothing else can bring a player into existence.
create table public.players (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid unique references auth.users(id) on delete set null,
  -- Copied from the JWT at sign-up.
  email      text,
  name       text not null check (length(btrim(name)) between 1 and 40),
  team_id    uuid references public.teams(id) on delete set null,
  slot       smallint check (slot in (1, 2)),
  is_admin   boolean not null default false,
  -- is_active=false → an admin-only login: never in the pool, never on a team.
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  -- Either on a team in a numbered slot, or in the pool. Never half of each.
  constraint team_and_slot_together check ((team_id is null) = (slot is null)),
  -- Two players per team, one per slot. Postgres treats nulls as distinct, so
  -- the whole pool can sit here without colliding.
  unique (team_id, slot)
);

-- Names are the sign-in handle, so they are unique case-insensitively.
create unique index players_name_key on public.players (lower(btrim(name)));
create index players_team_idx on public.players (team_id);

-- Teammate requests. One unteamed player asks another; the team exists only
-- once the second accepts. There is no other way to form a team.
create table public.team_requests (
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

-- One live request out per player, so the pool cannot be spammed and "your
-- outgoing request" is always a single, cancellable thing.
create unique index team_requests_one_outgoing
  on public.team_requests (from_player) where status = 'pending';
create index team_requests_inbox_idx
  on public.team_requests (to_player) where status = 'pending';

create table public.league_settings (
  id                  int primary key default 1 check (id = 1),
  season_name         text not null default 'Season 1',
  games_per_team      int  not null default 10 check (games_per_team between 1 and 200),
  buy_in_cents        int  not null default 5000 check (buy_in_cents >= 0),
  -- Whoever signs up with this address gets the admin controls.
  admin_email         text not null default 'matilevi13@gmail.com',
  -- Set when the admin opens the season. Until then teams are still forming and
  -- either member may walk away; afterwards team changes are admin-only.
  season_started_at   timestamptz,
  playoff_size        int  check (playoff_size in (4, 8, 16)),
  phase               text not null default 'league' check (phase in ('league','playoffs','complete')),
  champion_team_id    uuid references public.teams(id) on delete set null,
  playoffs_started_at timestamptz,
  updated_at          timestamptz not null default now()
);

create table public.matches (
  id            uuid primary key default gen_random_uuid(),
  phase         text not null check (phase in ('league','playoff')),
  -- playoff bracket coordinates; null for league games
  round         int,
  slot          int,
  team_a        uuid references public.teams(id) on delete cascade,
  team_b        uuid references public.teams(id) on delete cascade,
  seed_a        int,
  seed_b        int,
  score_a       int check (score_a >= 0 and score_a <= 99),
  score_b       int check (score_b >= 0 and score_b <= 99),
  winner_id     uuid references public.teams(id) on delete set null,
  status        text not null default 'pending'
                check (status in ('scheduled','pending','confirmed','disputed','voided')),
  submitted_by  uuid references public.teams(id) on delete set null,
  confirmed_by  uuid references public.teams(id) on delete set null,
  admin_note    text,
  created_at    timestamptz not null default now(),
  confirmed_at  timestamptz,
  updated_at    timestamptz not null default now(),
  -- Empty bracket slots are legitimately (null, null); only reject a team
  -- drawn against itself.
  constraint different_teams check (team_a is null or team_b is null or team_a <> team_b),
  constraint league_has_both_teams check (phase <> 'league' or (team_a is not null and team_b is not null)),
  -- Every result has a winner. Draws are not a thing in this league.
  constraint no_drawn_results check (
    status <> 'confirmed' or score_a is null or score_b is null or score_a <> score_b
  )
);

create unique index matches_bracket_slot_idx
  on public.matches (round, slot) where phase = 'playoff';
create index matches_team_a_idx  on public.matches (team_a);
create index matches_team_b_idx  on public.matches (team_b);
create index matches_status_idx  on public.matches (status);

-- One public room. `kind` separates what players type from what the league
-- posts on their behalf.
create table public.messages (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null default 'chat' check (kind in ('chat','result','taunt')),
  author_id  uuid references public.players(id) on delete set null,
  -- Denormalised so a message still reads correctly after a player is renamed,
  -- leaves a team, or is deleted.
  author_name text,
  team_name   text,
  body       text check (body is null or length(btrim(body)) between 1 and 500),
  -- result and taunt messages hang off the match they describe
  match_id   uuid references public.matches(id) on delete cascade,
  -- clock_timestamp(), not now(): a result and its taunt can land in the same
  -- transaction, and now() would give them identical timestamps to sort by.
  created_at timestamptz not null default clock_timestamp(),
  constraint chat_needs_body   check (kind <> 'chat'  or (body is not null and author_id is not null)),
  constraint taunt_needs_match check (kind <> 'taunt' or match_id is not null),
  constraint result_needs_match check (kind <> 'result' or match_id is not null)
);

create index messages_created_idx on public.messages (created_at desc);
-- One taunt per match, enforced in the database rather than by hoping.
create unique index messages_one_taunt_per_match
  on public.messages (match_id) where kind = 'taunt';
create unique index messages_one_result_per_match
  on public.messages (match_id) where kind = 'result';

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
alter table public.team_requests   enable row level security;
alter table public.league_settings enable row level security;
alter table public.matches         enable row level security;

create policy teams_read    on public.teams           for select to authenticated using (true);
create policy players_read  on public.players         for select to authenticated using (true);
create policy settings_read on public.league_settings for select to authenticated using (true);
create policy matches_read  on public.matches         for select to authenticated using (true);
create policy messages_read on public.messages        for select to authenticated using (true);

-- A player sees only the requests they sent or received.
create policy requests_read on public.team_requests for select to authenticated
  using (from_player = public.current_player_id() or to_player = public.current_player_id());


-- ---------------------------------------------------------------------------
-- Accounts
--
-- Supabase Auth owns email and password. This layer owns the username, which
-- is the identity everyone actually sees, and works out who the admin is.
--
-- A profile row is created by a trigger the instant the auth user is created,
-- so a signed-in account without a profile is not a state that can occur. The
-- client never inserts into players itself; claim_account and ensure_account
-- both reconcile through the same core below, so the three paths cannot drift.
-- ---------------------------------------------------------------------------

-- Best-effort: make sure p_uid owns exactly one profile row and hand back its
-- id. Never raises. Players only ever exist by signing themselves up, so this
-- creates a row for the authenticated user and nothing else — it cannot invent
-- a player on somebody else's behalf.
create or replace function public.attach_player(
  p_uid uuid, p_email text, p_wanted text
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  my_email    text := lower(btrim(coalesce(p_email, '')));
  wanted      text := nullif(btrim(coalesce(p_wanted, '')), '');
  admin_email text;
  mine        public.players%rowtype;
  base        text;
  candidate   text;
  n           int := 1;
  new_id      uuid;
  name_free   boolean;
begin
  select lower(btrim(ls.admin_email)) into admin_email
    from public.league_settings ls where ls.id = 1;

  select * into mine from public.players where user_id = p_uid;

  if mine.id is not null then
    select not exists (
      select 1 from public.players
       where lower(btrim(name)) = lower(coalesce(wanted, ''))
         and id <> mine.id
    ) into name_free;

    update public.players
       set email    = coalesce(nullif(my_email, ''), email),
           name     = case when wanted is not null and name_free then wanted else name end,
           is_admin = (lower(btrim(coalesce(nullif(my_email, ''), email, ''))) = admin_email)
     where id = mine.id;
    return mine.id;
  end if;

  -- Take the wanted name, or derive one from the email, suffixing until it is
  -- free so this can never fail on a collision.
  base := left(coalesce(wanted, nullif(btrim(split_part(my_email, '@', 1)), ''), 'player'), 36);
  candidate := base;
  while exists (select 1 from public.players where lower(btrim(name)) = lower(candidate)) loop
    n := n + 1;
    candidate := base || ' ' || n;
  end loop;

  insert into public.players (user_id, email, name, is_admin)
  values (p_uid, nullif(my_email, ''), candidate, my_email = admin_email)
  returning id into new_id;
  return new_id;
end;
$$;

-- Fires the moment Supabase Auth creates the user, so the profile exists before
-- the client asks for it. The username comes from the sign-up metadata.
--
-- This must never raise: an exception here would roll back the auth user and
-- break sign-up entirely, which is worse than the problem it solves. On failure
-- it warns and lets ensure_account() repair the row on first load.
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.attach_player(
    new.id,
    new.email,
    nullif(btrim(coalesce(new.raw_user_meta_data ->> 'username', '')), '')
  );
  return new;
exception when others then
  raise warning 'handle_new_auth_user could not create a profile for %: %', new.id, sqlerrm;
  return new;
end;
$$;

-- auth.users belongs to Supabase, so attaching to it can be refused on some
-- projects. Losing the trigger is survivable — ensure_account() still repairs
-- the row on first load — but losing the whole migration is not, so a refusal
-- warns instead of aborting.
do $$
begin
  drop trigger if exists on_auth_user_created on auth.users;
  create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_auth_user();
  raise notice 'Auth trigger installed: profiles are created with the account.';
exception when insufficient_privilege or undefined_table then
  raise warning 'Could not attach the trigger to auth.users (%). Profiles will '
                'instead be created by ensure_account() on first load.', sqlerrm;
end $$;

-- Lets the sign-up form say "that one's taken" before creating the account,
-- rather than after. Anonymous, and tells you nothing but yes/no.
create or replace function public.username_available(p_username text)
returns boolean language sql stable security definer set search_path = public as $$
  select nullif(btrim(coalesce(p_username, '')), '') is not null
     and not exists (
       select 1 from public.players
        where lower(btrim(name)) = lower(btrim(p_username))
     );
$$;

-- Called straight after signUp to settle the username. The trigger has usually
-- done the work already; this reconciles the cases it could not (metadata
-- missing, or an account created before the trigger existed).
create or replace function public.claim_account(p_username text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  uid      uuid := auth.uid();
  my_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  wanted   text := nullif(btrim(coalesce(p_username, '')), '');
begin
  if uid is null then
    raise exception 'Not signed in.' using errcode = 'P0001';
  end if;
  if wanted is null or length(wanted) > 40 then
    raise exception 'Pick a username between 1 and 40 characters.' using errcode = 'P0001';
  end if;

  -- Taken by somebody else.
  if exists (
    select 1 from public.players
     where lower(btrim(name)) = lower(wanted)
       and user_id <> uid
  ) then
    raise exception 'The username "%" is taken. Pick another.', wanted using errcode = 'P0001';
  end if;

  return public.attach_player(uid, my_email, wanted);
end;
$$;

-- Re-derives every admin flag from the configured address. Called after the
-- admin email changes, so the controls move with it.
create or replace function public.sync_admin_flags()
returns void language plpgsql security definer set search_path = public as $$
declare admin_email text;
begin
  select lower(btrim(ls.admin_email)) into admin_email
    from public.league_settings ls where ls.id = 1;
  update public.players
     set is_admin = (lower(btrim(coalesce(email, ''))) = admin_email)
   where is_admin is distinct from (lower(btrim(coalesce(email, ''))) = admin_email);
end;
$$;

-- Safety net for a signed-in account with no profile — one created before the
-- trigger existed, or a sign-up interrupted midway. Idempotent.
create or replace function public.ensure_account()
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Not signed in.' using errcode = 'P0001';
  end if;
  return public.attach_player(uid, lower(btrim(coalesce(auth.jwt() ->> 'email', ''))), null);
end;
$$;

-- ---------------------------------------------------------------------------
-- Season state
-- ---------------------------------------------------------------------------

-- The season has started if the admin said so, or if anything has actually
-- happened — a confirmed result, or the playoffs. The last two matter because
-- an admin who forgets to press the button should not leave the league in a
-- state where somebody can dissolve a team that has already played.
create or replace function public.season_has_started()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
           (select ls.season_started_at is not null or ls.phase <> 'league'
              from public.league_settings ls where ls.id = 1),
           false)
      or exists (select 1 from public.matches where status = 'confirmed');
$$;

create or replace function public.admin_set_season_started(p_started boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  update public.league_settings
     set season_started_at = case when p_started then coalesce(season_started_at, now()) end,
         updated_at = now()
   where id = 1;
end;
$$;

-- ---------------------------------------------------------------------------
-- Teams
--
-- A team is formed by mutual consent and no other way. One unteamed player
-- asks another; the team exists only when the second accepts. Nothing here
-- can bring a player into existence — everyone signs themselves up.
-- ---------------------------------------------------------------------------

-- Kills every live request touching a player. Called whenever they stop being
-- available, so nobody is left holding a request against someone teamed.
create or replace function public.expire_requests_for(p_player_id uuid)
returns void language sql security definer set search_path = public as $$
  update public.team_requests
     set status = 'expired', responded_at = now()
   where status = 'pending'
     and (from_player = p_player_id or to_player = p_player_id);
$$;

create or replace function public.send_teammate_request(
  p_to_player uuid, p_team_name text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  me     public.players%rowtype;
  target public.players%rowtype;
  wanted text := nullif(btrim(coalesce(p_team_name, '')), '');
  new_id uuid;
begin
  select * into me from public.players where user_id = auth.uid();
  if not found then raise exception 'Not signed in.' using errcode = 'P0001'; end if;
  if me.id = p_to_player then
    raise exception 'You cannot team up with yourself.' using errcode = 'P0001';
  end if;
  if me.team_id is not null then
    raise exception 'You are already on a team.' using errcode = 'P0001';
  end if;

  select * into target from public.players where id = p_to_player;
  if not found or not target.is_active then
    raise exception 'That player is not in the league.' using errcode = 'P0002';
  end if;
  if target.user_id is null then
    raise exception 'That player has not signed up yet.' using errcode = 'P0001';
  end if;
  if target.team_id is not null then
    raise exception '% is already on a team.', target.name using errcode = 'P0001';
  end if;
  if wanted is not null and length(wanted) > 40 then
    raise exception 'Team names top out at 40 characters.' using errcode = 'P0001';
  end if;
  if wanted is not null
     and exists (select 1 from public.teams where lower(btrim(name)) = lower(wanted)) then
    raise exception 'A team called "%" already exists.', wanted using errcode = 'P0001';
  end if;
  if exists (select 1 from public.team_requests
              where from_player = me.id and status = 'pending') then
    raise exception 'You already have a request out. Cancel it first.' using errcode = 'P0001';
  end if;

  insert into public.team_requests (from_player, to_player, proposed_team_name)
  values (me.id, p_to_player, wanted)
  returning id into new_id;
  return new_id;
end;
$$;

create or replace function public.cancel_teammate_request(p_request_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_player_id(); r public.team_requests%rowtype;
begin
  select * into r from public.team_requests where id = p_request_id for update;
  if not found then raise exception 'Request not found.' using errcode = 'P0002'; end if;
  if r.from_player <> me then
    raise exception 'That is not your request to cancel.' using errcode = 'P0001';
  end if;
  if r.status <> 'pending' then
    raise exception 'That request is no longer open.' using errcode = 'P0001';
  end if;
  update public.team_requests set status = 'cancelled', responded_at = now()
   where id = p_request_id;
end;
$$;

create or replace function public.decline_teammate_request(p_request_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_player_id(); r public.team_requests%rowtype;
begin
  select * into r from public.team_requests where id = p_request_id for update;
  if not found then raise exception 'Request not found.' using errcode = 'P0002'; end if;
  if r.to_player <> me then
    raise exception 'That request was not sent to you.' using errcode = 'P0001';
  end if;
  if r.status <> 'pending' then
    raise exception 'That request is no longer open.' using errcode = 'P0001';
  end if;
  update public.team_requests set status = 'declined', responded_at = now()
   where id = p_request_id;
end;
$$;

-- Accepting is what creates the team. The accepting player has the final say on
-- the name; the proposal is only a default.
create or replace function public.accept_teammate_request(
  p_request_id uuid, p_team_name text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  me        uuid := public.current_player_id();
  r         public.team_requests%rowtype;
  mate      public.players%rowtype;
  my_row    public.players%rowtype;
  team_name text;
  new_team  uuid;
begin
  select * into r from public.team_requests where id = p_request_id for update;
  if not found then raise exception 'Request not found.' using errcode = 'P0002'; end if;
  if r.to_player <> me then
    raise exception 'That request was not sent to you.' using errcode = 'P0001';
  end if;
  if r.status <> 'pending' then
    raise exception 'That request is no longer open.' using errcode = 'P0001';
  end if;

  select * into my_row from public.players where id = me for update;
  select * into mate   from public.players where id = r.from_player for update;

  if my_row.team_id is not null then
    raise exception 'You are already on a team.' using errcode = 'P0001';
  end if;
  if mate.team_id is not null then
    update public.team_requests set status = 'expired', responded_at = now()
     where id = p_request_id;
    raise exception '% joined another team first.', mate.name using errcode = 'P0001';
  end if;

  team_name := nullif(btrim(coalesce(p_team_name, r.proposed_team_name, '')), '');
  if team_name is null then
    raise exception 'Give the team a name.' using errcode = 'P0001';
  end if;
  if length(team_name) > 40 then
    raise exception 'Team names top out at 40 characters.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.teams where lower(btrim(name)) = lower(team_name)) then
    raise exception 'A team called "%" already exists.', team_name using errcode = 'P0001';
  end if;

  insert into public.teams (name) values (team_name) returning id into new_team;

  -- The player who asked takes slot 1, the one who accepted takes slot 2.
  update public.players set team_id = new_team, slot = 1 where id = mate.id;
  update public.players set team_id = new_team, slot = 2 where id = me;

  update public.team_requests set status = 'accepted', responded_at = now()
   where id = p_request_id;
  perform public.expire_requests_for(me);
  perform public.expire_requests_for(mate.id);

  return new_team;
end;
$$;

-- Either teammate can walk away while the season has not started. It dissolves
-- the team outright rather than leaving somebody stranded in a team of one, so
-- both players land back in the pool and the name is free again.
create or replace function public.leave_team()
returns void language plpgsql security definer set search_path = public as $$
declare
  me       public.players%rowtype;
  team_row public.teams%rowtype;
  mate_id  uuid;
begin
  select * into me from public.players where user_id = auth.uid() for update;
  if not found then raise exception 'Not signed in.' using errcode = 'P0001'; end if;
  if me.team_id is null then
    raise exception 'You are not on a team.' using errcode = 'P0001';
  end if;
  if public.season_has_started() then
    raise exception 'The season has started — ask the admin to change teams now.'
      using errcode = 'P0001';
  end if;

  select * into team_row from public.teams where id = me.team_id for update;
  select id into mate_id from public.players
   where team_id = me.team_id and id <> me.id limit 1;

  -- Free both before the team goes, so slot never outlives team_id.
  update public.players set team_id = null, slot = null where team_id = team_row.id;
  delete from public.matches where team_a = team_row.id or team_b = team_row.id;
  delete from public.teams where id = team_row.id;

  -- Everyone starts fresh: old requests stay expired rather than coming back.
  perform public.expire_requests_for(me.id);
  if mate_id is not null then perform public.expire_requests_for(mate_id); end if;
end;
$$;

-- Either teammate can rename their own team, at any time.
create or replace function public.rename_team(p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare me public.players%rowtype; wanted text := nullif(btrim(coalesce(p_name, '')), '');
begin
  select * into me from public.players where user_id = auth.uid();
  if not found then raise exception 'Not signed in.' using errcode = 'P0001'; end if;
  if me.team_id is null then
    raise exception 'You are not on a team.' using errcode = 'P0001';
  end if;
  if wanted is null then
    raise exception 'Give the team a name.' using errcode = 'P0001';
  end if;
  if length(wanted) > 40 then
    raise exception 'Team names top out at 40 characters.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.teams
              where lower(btrim(name)) = lower(wanted) and id <> me.team_id) then
    raise exception 'A team called "%" already exists.', wanted using errcode = 'P0001';
  end if;

  update public.teams set name = wanted where id = me.team_id;
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
  perform public.expire_requests_for(a.id);
  perform public.expire_requests_for(b.id);
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
                public.matches, public.standings, public.messages,
                public.team_requests
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
  public.username_available(text)
  to anon, authenticated;

grant execute on function
  public.claim_account(text),
  public.ensure_account(),
  public.current_player_id(),
  public.current_team_id(),
  public.is_admin(),
  public.send_teammate_request(uuid, text),
  public.cancel_teammate_request(uuid),
  public.decline_teammate_request(uuid),
  public.accept_teammate_request(uuid, text),
  public.rename_team(text),
  public.leave_team(),
  public.season_has_started(),
  public.submit_league_result(uuid, int, int),
  public.submit_playoff_result(uuid, int, int),
  public.confirm_match(uuid),
  public.dispute_match(uuid),
  public.cancel_submission(uuid),
  public.admin_rename_player(uuid, text),
  public.admin_delete_player(uuid),
  public.admin_create_team(text, uuid, uuid),
  public.admin_update_team(uuid, text, boolean, boolean),
  public.admin_dissolve_team(uuid),
  public.admin_update_settings(text, int, int, int, text),
  public.admin_set_season_started(boolean),
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
  foreach t in array array['matches','teams','players','league_settings','messages','team_requests'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Seed: just the league row. The admin account creates itself the moment
-- someone signs up with the address in league_settings.admin_email.
-- ---------------------------------------------------------------------------

insert into public.league_settings (id) values (1) on conflict (id) do nothing;

do $$
declare who text;
begin
  select admin_email into who from public.league_settings where id = 1;
  raise notice '=================================================';
  raise notice ' Ready. Sign up with % to get the admin controls.', who;
  raise notice ' Keep "Confirm email" OFF in Supabase Auth.';
  raise notice '=================================================';
end;
$$;
