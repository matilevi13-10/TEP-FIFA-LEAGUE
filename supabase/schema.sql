-- ============================================================================
-- TEP FIFA LEAGUE — full schema
-- Run this once in the Supabase SQL Editor (Dashboard → SQL Editor → New query).
-- Safe to re-run: it drops and recreates everything in the public schema it owns.
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Teardown (idempotent re-runs)
-- ---------------------------------------------------------------------------
drop view   if exists public.standings cascade;
drop table  if exists public.matches cascade;
drop table  if exists public.team_secrets cascade;
drop table  if exists public.league_settings cascade;
drop table  if exists public.teams cascade;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.teams (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid unique references auth.users(id) on delete set null,
  name        text not null unique check (length(btrim(name)) between 1 and 40),
  player_one  text not null check (length(btrim(player_one)) between 1 and 40),
  player_two  text not null check (length(btrim(player_two)) between 1 and 40),
  is_admin    boolean not null default false,
  -- is_active=false → an admin-only login: excluded from the table, the pot and
  -- every opponent picker.
  is_active   boolean not null default true,
  paid        boolean not null default false,
  created_at  timestamptz not null default now()
);

-- PIN material lives in its own table with NO select policy, so a signed-in
-- player can never read another team's hash. Only SECURITY DEFINER functions
-- below ever touch it.
create table public.team_secrets (
  team_id       uuid primary key references public.teams(id) on delete cascade,
  pin_hash      text not null,
  -- Long random secret used as the real Supabase Auth password. Released to the
  -- client only after the PIN is verified, so the PIN is the only thing a player
  -- has to know and brute force has to go through the rate limiter below.
  auth_key      text not null default encode(extensions.gen_random_bytes(32), 'hex'),
  failed_count  int not null default 0,
  locked_until  timestamptz
);

create table public.league_settings (
  id                  int primary key default 1 check (id = 1),
  season_name         text not null default 'Season 1',
  games_per_team      int  not null default 10 check (games_per_team between 1 and 200),
  buy_in_cents        int  not null default 5000 check (buy_in_cents >= 0),
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
  constraint league_has_both_teams check (phase <> 'league' or (team_a is not null and team_b is not null))
);

create unique index matches_bracket_slot_idx
  on public.matches (round, slot) where phase = 'playoff';
create index matches_team_a_idx  on public.matches (team_a);
create index matches_team_b_idx  on public.matches (team_b);
create index matches_status_idx  on public.matches (status);

-- ---------------------------------------------------------------------------
-- Identity helpers
-- ---------------------------------------------------------------------------

create or replace function public.current_team_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.teams where user_id = auth.uid();
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.teams where user_id = auth.uid()), false);
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
    (count(*) filter (where p.gf = p.ga))::int           as drawn,
    (count(*) filter (where p.gf < p.ga))::int           as lost,
    coalesce(sum(p.gf), 0)::int                          as goals_for,
    coalesce(sum(p.ga), 0)::int                          as goals_against,
    (count(*) filter (where p.gf > p.ga) * 3
       + count(*) filter (where p.gf = p.ga))::int       as points
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
--   Reads: every signed-in player sees every team, match and setting.
--   Writes: no direct writes at all — everything goes through the RPCs below,
--   which validate rules server-side.
-- ---------------------------------------------------------------------------

alter table public.teams           enable row level security;
alter table public.team_secrets    enable row level security;
alter table public.league_settings enable row level security;
alter table public.matches         enable row level security;

create policy teams_read    on public.teams           for select to authenticated using (true);
create policy settings_read on public.league_settings for select to authenticated using (true);
create policy matches_read  on public.matches         for select to authenticated using (true);
-- team_secrets intentionally has zero policies: RLS on + no policy = deny all.

-- ---------------------------------------------------------------------------
-- Sign-in
-- ---------------------------------------------------------------------------

-- Anonymous, safe-column-only team list for the sign-in picker.
create or replace function public.list_teams_for_signin()
returns table (id uuid, name text, player_one text, player_two text, is_active boolean)
language sql stable security definer set search_path = public as $$
  select id, name, player_one, player_two, is_active
  from public.teams order by is_active desc, name asc;
$$;

-- Verifies the PIN and, only on success, hands back the Supabase Auth
-- credentials for this team. Rate limited: 8 misses locks the team for 15 min.
create or replace function public.begin_signin(p_team_id uuid, p_pin text)
returns json language plpgsql security definer set search_path = public as $$
declare
  s          public.team_secrets%rowtype;
  t          public.teams%rowtype;
  auth_email text;
begin
  select * into t from public.teams where id = p_team_id;
  if not found then
    raise exception 'That team no longer exists.' using errcode = 'P0002';
  end if;

  select * into s from public.team_secrets where team_id = p_team_id for update;
  if not found then
    raise exception 'This team has no PIN set. Ask the admin to reset it.' using errcode = 'P0002';
  end if;

  if s.locked_until is not null and s.locked_until > now() then
    raise exception 'Too many wrong PINs. Try again in % minutes.',
      greatest(1, ceil(extract(epoch from (s.locked_until - now())) / 60))
      using errcode = 'P0001';
  end if;

  if s.pin_hash <> extensions.crypt(p_pin, s.pin_hash) then
    update public.team_secrets
       set failed_count = failed_count + 1,
           locked_until = case when failed_count + 1 >= 8 then now() + interval '15 minutes' end
     where team_id = p_team_id;
    raise exception 'Wrong PIN.' using errcode = 'P0001';
  end if;

  update public.team_secrets
     set failed_count = 0, locked_until = null
   where team_id = p_team_id;

  auth_email := 'team-' || replace(p_team_id::text, '-', '') || '@tepfifa.app';
  return json_build_object(
    'email',        auth_email,
    'auth_key',     s.auth_key,
    'needs_signup', t.user_id is null
  );
end;
$$;

-- Binds the freshly created auth user to the team. Re-checks the PIN so a
-- stray signup can never attach itself to a team.
create or replace function public.link_account(p_team_id uuid, p_pin text)
returns void language plpgsql security definer set search_path = public as $$
declare s public.team_secrets%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Not signed in.' using errcode = 'P0001';
  end if;
  select * into s from public.team_secrets where team_id = p_team_id;
  if not found or s.pin_hash <> extensions.crypt(p_pin, s.pin_hash) then
    raise exception 'Wrong PIN.' using errcode = 'P0001';
  end if;
  update public.teams set user_id = auth.uid()
   where id = p_team_id and user_id is null;
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

-- Records a league result. The winning team submits; on a draw either may.
create or replace function public.submit_league_result(
  p_opponent uuid, p_my_score int, p_opp_score int
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  me       uuid := public.current_team_id();
  cfg      public.league_settings%rowtype;
  opp      public.teams%rowtype;
  new_id   uuid;
begin
  if me is null then raise exception 'Not signed in.' using errcode = 'P0001'; end if;
  if me = p_opponent then raise exception 'Pick an opponent other than your own team.' using errcode = 'P0001'; end if;

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

-- Records a playoff result into an existing bracket slot. No draws.
create or replace function public.submit_playoff_result(
  p_match_id uuid, p_my_score int, p_opp_score int
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.current_team_id();
  m  public.matches%rowtype;
begin
  if me is null then raise exception 'Not signed in.' using errcode = 'P0001'; end if;

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
    raise exception 'Playoff games cannot end level — play it out.' using errcode = 'P0001';
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

-- The opponent approves. Nothing counts until this runs.
create or replace function public.confirm_match(p_match_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.current_team_id();
  m  public.matches%rowtype;
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
         winner_id    = case when score_a > score_b then team_a
                             when score_b > score_a then team_b end,
         updated_at   = now()
   where id = p_match_id;
end;
$$;

create or replace function public.dispute_match(p_match_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.current_team_id();
  m  public.matches%rowtype;
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

-- Lets the submitter take back their own pending submission (mistyped score).
create or replace function public.cancel_submission(p_match_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.current_team_id();
  m  public.matches%rowtype;
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

create or replace function public.on_match_confirmed()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.phase = 'playoff' and new.status = 'confirmed'
     and old.status is distinct from 'confirmed' then
    perform public.push_winner(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists match_confirmed on public.matches;
create trigger match_confirmed after update on public.matches
  for each row execute function public.on_match_confirmed();

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

create or replace function public.admin_create_team(
  p_name text, p_player_one text, p_player_two text, p_pin text
) returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  perform public.assert_admin();
  if p_pin !~ '^[0-9]{4}$' then
    raise exception 'The PIN has to be exactly 4 digits.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.teams where lower(btrim(name)) = lower(btrim(p_name))) then
    raise exception 'A team called "%" already exists.', btrim(p_name) using errcode = 'P0001';
  end if;

  insert into public.teams (name, player_one, player_two)
  values (btrim(p_name), btrim(p_player_one), btrim(p_player_two))
  returning id into new_id;

  insert into public.team_secrets (team_id, pin_hash)
  values (new_id, extensions.crypt(p_pin, extensions.gen_salt('bf')));

  return new_id;
end;
$$;

create or replace function public.admin_update_team(
  p_team_id uuid, p_name text, p_player_one text, p_player_two text,
  p_is_active boolean, p_paid boolean
) returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if exists (select 1 from public.teams
              where lower(btrim(name)) = lower(btrim(p_name)) and id <> p_team_id) then
    raise exception 'A team called "%" already exists.', btrim(p_name) using errcode = 'P0001';
  end if;
  update public.teams
     set name = btrim(p_name), player_one = btrim(p_player_one),
         player_two = btrim(p_player_two), is_active = p_is_active, paid = p_paid
   where id = p_team_id;
end;
$$;

create or replace function public.admin_set_pin(p_team_id uuid, p_pin text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_pin !~ '^[0-9]{4}$' then
    raise exception 'The PIN has to be exactly 4 digits.' using errcode = 'P0001';
  end if;
  insert into public.team_secrets (team_id, pin_hash)
  values (p_team_id, extensions.crypt(p_pin, extensions.gen_salt('bf')))
  on conflict (team_id) do update
     set pin_hash = excluded.pin_hash, failed_count = 0, locked_until = null;
end;
$$;

create or replace function public.admin_set_role(p_team_id uuid, p_is_admin boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if not p_is_admin
     and (select count(*) from public.teams where is_admin) <= 1
     and (select is_admin from public.teams where id = p_team_id) then
    raise exception 'The league needs at least one admin.' using errcode = 'P0001';
  end if;
  update public.teams set is_admin = p_is_admin where id = p_team_id;
end;
$$;

create or replace function public.admin_delete_team(p_team_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if (select phase from public.league_settings where id = 1) <> 'league' then
    raise exception 'Teams cannot be removed once the playoffs have started.' using errcode = 'P0001';
  end if;
  delete from public.teams where id = p_team_id;
end;
$$;

create or replace function public.admin_update_settings(
  p_season_name text, p_games_per_team int, p_buy_in_cents int, p_playoff_size int
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
         buy_in_cents = p_buy_in_cents, playoff_size = p_playoff_size, updated_at = now()
   where id = 1;
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
  i            int;
  r            int;
  s            int;
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
  if m.phase = 'playoff' and p_score_a = p_score_b then
    raise exception 'Playoff games cannot end level.' using errcode = 'P0001';
  end if;

  if m.phase = 'playoff' and m.status = 'confirmed' then
    perform public.clear_from(m.round, m.slot);
  end if;

  update public.matches
     set score_a = p_score_a, score_b = p_score_b, status = 'confirmed',
         winner_id = case when p_score_a > p_score_b then team_a
                          when p_score_b > p_score_a then team_b end,
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
grant select on public.teams, public.league_settings, public.matches, public.standings
  to authenticated;

-- Belt and braces: Supabase's default privileges grant new public tables to
-- anon/authenticated, so take PIN material back explicitly. RLS on this table
-- already denies everything, this makes it fail one layer earlier.
revoke all on public.team_secrets from anon, authenticated;

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
  public.list_teams_for_signin(),
  public.begin_signin(uuid, text)
  to anon, authenticated;

grant execute on function
  public.link_account(uuid, text),
  public.submit_league_result(uuid, int, int),
  public.submit_playoff_result(uuid, int, int),
  public.confirm_match(uuid),
  public.dispute_match(uuid),
  public.cancel_submission(uuid),
  public.current_team_id(),
  public.is_admin(),
  public.admin_create_team(text, text, text, text),
  public.admin_update_team(uuid, text, text, text, boolean, boolean),
  public.admin_set_pin(uuid, text),
  public.admin_set_role(uuid, boolean),
  public.admin_delete_team(uuid),
  public.admin_update_settings(text, int, int, int),
  public.admin_start_playoffs(int),
  public.admin_reset_playoffs(),
  public.admin_resolve_match(uuid, int, int, text),
  public.admin_void_match(uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Realtime — every phone re-renders the moment a result lands.
-- ---------------------------------------------------------------------------

do $$
begin
  begin execute 'alter publication supabase_realtime add table public.matches';
  exception when duplicate_object then null; end;
  begin execute 'alter publication supabase_realtime add table public.teams';
  exception when duplicate_object then null; end;
  begin execute 'alter publication supabase_realtime add table public.league_settings';
  exception when duplicate_object then null; end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Seed: the league row and one admin login.
-- ---------------------------------------------------------------------------

insert into public.league_settings (id) values (1) on conflict (id) do nothing;

do $$
declare admin_id uuid;
begin
  insert into public.teams (name, player_one, player_two, is_admin, is_active)
  values ('Admin', 'League', 'Admin', true, false)
  returning id into admin_id;

  insert into public.team_secrets (team_id, pin_hash)
  values (admin_id, extensions.crypt('1234', extensions.gen_salt('bf')));

  raise notice '=================================================';
  raise notice ' Admin login created — team "Admin", PIN 1234';
  raise notice ' Change this PIN from the Admin screen right away.';
  raise notice '=================================================';
end;
$$;
