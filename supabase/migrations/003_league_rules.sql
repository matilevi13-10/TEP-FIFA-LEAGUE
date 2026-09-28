-- ============================================================================
-- TEP FIFA LEAGUE — migration 003: the league rules
--
-- Run this on a database that already has migration 002 (or was installed
-- from the schema before these rules). It brings it in line with the rules:
--   • The league is played in rounds, one a week: one opponent, two games,
--     one home game each. games_per_team sets the length and must be even —
--     12 games is 6 rounds, which with seven teams is everyone once.
--   • A game still level after extra time is a tie. Win 3, draw 1, loss 0;
--     level on points goes to goal difference, then goals scored.
--   • Penalties never count toward the score. When a level final or a level
--     aggregate goes to a shootout, the shootout winner is recorded on its own.
--   • Every team makes the playoffs. Spare bracket places go to the top seeds
--     as byes — with seven teams, only the #1 seed.
--   • Playoff ties are two legs on aggregate until the final, which is one
--     game. The higher seed is at home in the second leg and in the final.
--     Home picks their team and the console.
--
-- Safe on your live database: additive, wrapped in a transaction, re-runnable.
-- Teams, players, results and chat all survive. If the season has started
-- and nothing has been confirmed yet, the fixtures are rebuilt in the new
-- weekly format; if results already exist, the schedule is left alone.
--
-- GENERATED FILE — edit supabase/schema.sql, then run:
--   python3 supabase/migrations/build_003.py
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Structure
-- ---------------------------------------------------------------------------

alter table public.matches add column if not exists leg smallint not null default 1;
alter table public.matches add column if not exists home_team uuid
  references public.teams(id) on delete set null;
alter table public.matches add column if not exists shootout_winner uuid
  references public.teams(id) on delete set null;

-- You play each opponent twice, so games per team is always even. Round an
-- odd setting up rather than refuse to migrate.
update public.league_settings set games_per_team = least(200, games_per_team + 1)
 where games_per_team % 2 <> 0;
update public.league_settings set games_per_team = 2 where games_per_team < 2;
alter table public.league_settings drop constraint if exists league_settings_games_per_team_check;
alter table public.league_settings add constraint league_settings_games_per_team_check
  check (games_per_team between 2 and 200 and games_per_team % 2 = 0);

alter table public.matches drop constraint if exists matches_leg_check;
alter table public.matches add constraint matches_leg_check check (leg in (1, 2));

alter table public.matches drop constraint if exists matches_status_check;
alter table public.matches add constraint matches_status_check
  check (status in ('scheduled','pending','confirmed','disputed','voided','bye'));

-- Ties are allowed now.
alter table public.matches drop constraint if exists no_drawn_results;
alter table public.matches drop constraint if exists bye_is_playoff;
alter table public.matches add constraint bye_is_playoff
  check (status <> 'bye' or (phase = 'playoff' and team_b is null));

drop index if exists public.matches_bracket_slot_idx;
create unique index matches_bracket_slot_idx
  on public.matches (round, slot, leg) where phase = 'playoff';

alter table public.league_settings drop constraint if exists league_settings_playoff_size_check;
alter table public.league_settings add constraint league_settings_playoff_size_check
  check (playoff_size between 2 and 64);

-- Existing fixtures were single games with no home side; call team_a home.
update public.matches set home_team = team_a
 where phase = 'league' and home_team is null;

-- The table gains a drawn column, which create or replace cannot insert.
drop view if exists public.standings;
-- Everyone qualifies now, so the playoffs no longer take a size.
drop function if exists public.admin_start_playoffs(int);
-- These grew a shootout-winner argument.
drop function if exists public.submit_playoff_result(uuid, int, int);
drop function if exists public.admin_resolve_match(uuid, int, int, text);
drop function if exists public.check_playoff_score(public.matches, int, int);

-- ---------------------------------------------------------------------------
-- 2. Functions, policies, grants (identical to schema.sql)
-- ---------------------------------------------------------------------------

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
-- Only confirmed league matches count. Win 3, draw 1, loss 0; level on points
-- goes to goal difference, then goals scored.
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
     + count(*) filter (where p.gf = p.ga))::int         as points
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

-- A player sees only the requests they sent or received.
drop policy if exists requests_read on public.team_requests;
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
-- Fixtures
--
-- The league is played in rounds, one a week: each round you face one
-- opponent and play them twice, one home game each. games_per_team sets the
-- length, so 12 games is 6 rounds. With seven teams that is everyone once,
-- over seven weeks, each team sitting one week out.
-- ---------------------------------------------------------------------------

-- Builds the league schedule for the active teams and returns how many games it
-- made. Wipes any existing league fixtures first, so it doubles as regenerate.
--
-- Method: the circle method gives one cycle in which every team meets every
-- other exactly once (with a week off each if the count is odd). Cycles are
-- laid down back to back, each independently shuffled, and a pairing is
-- skipped once either side already has all its rounds. That caps everyone at
-- games_per_team / 2 opponents without anyone meeting the same opponent again
-- while a first meeting is still outstanding. Every pairing is two games.
create or replace function public.generate_schedule()
returns int language plpgsql security definer set search_path = public as $$
declare
  ids      uuid[];
  n        int;
  slots    int;
  target   int;
  arr      int[];
  played   int[];
  week     int := 0;
  slot_no  int;
  made     int := 0;
  cycle    int;
  r        int;
  i        int;
  a        int;
  b        int;
  emitted  boolean;
  carry    int;
begin
  delete from public.matches where phase = 'league';

  select array_agg(id order by random()) into ids
    from public.teams where is_active;
  n := coalesce(array_length(ids, 1), 0);
  if n < 2 then return 0; end if;

  -- Rounds per team: two games against each opponent.
  select games_per_team / 2 into target from public.league_settings where id = 1;
  -- The cap below keeps a silly setting from looping forever.
  target := least(greatest(target, 1), (n - 1) * 20);

  played := array_fill(0, array[n]);
  -- An odd count gets a phantom slot; whoever draws it has the week off.
  slots := case when n % 2 = 0 then n else n + 1 end;

  for cycle in 1 .. target loop
    -- Fresh shuffle each cycle so repeat meetings do not follow the same order.
    select array_agg(x order by random()) into arr
      from generate_series(1, slots) as g(x);

    for r in 1 .. slots - 1 loop
      emitted := false;
      slot_no := 0;

      for i in 1 .. slots / 2 loop
        a := arr[i];
        b := arr[slots + 1 - i];
        -- Skip the phantom, and skip anyone who already has all their rounds.
        if a <= n and b <= n and played[a] < target and played[b] < target then
          played[a] := played[a] + 1;
          played[b] := played[b] + 1;
          -- Alternate who hosts the first game, so nobody is always first at home.
          if (week + i) % 2 = 0 then carry := a; a := b; b := carry; end if;
          insert into public.matches (phase, round, slot, leg, team_a, team_b, home_team, status)
          values ('league', week + 1, slot_no, 1, ids[a], ids[b], ids[a], 'scheduled'),
                 ('league', week + 1, slot_no, 2, ids[a], ids[b], ids[b], 'scheduled');
          slot_no := slot_no + 1;
          made := made + 2;
          emitted := true;
        end if;
      end loop;

      if emitted then week := week + 1; end if;

      -- Rotate every slot but the first — the circle method.
      carry := arr[slots];
      for i in reverse slots .. 3 loop
        arr[i] := arr[i - 1];
      end loop;
      arr[2] := carry;
    end loop;

    exit when (select min(x) from unnest(played) as t(x)) >= target;
  end loop;

  return made;
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

-- Starting the season locks the teams and lays down the fixtures in one action.
-- Reopening it takes the schedule away again, which is only allowed while
-- nothing has been played.
create or replace function public.admin_set_season_started(p_started boolean)
returns int language plpgsql security definer set search_path = public as $$
declare made int := 0;
begin
  perform public.assert_admin();

  if p_started then
    if (select season_started_at is null from public.league_settings where id = 1) then
      made := public.generate_schedule();
    end if;
    update public.league_settings
       set season_started_at = coalesce(season_started_at, now()), updated_at = now()
     where id = 1;
  else
    if exists (select 1 from public.matches where status = 'confirmed') then
      raise exception 'Results have already been confirmed — the season cannot be reopened.'
        using errcode = 'P0001';
    end if;
    delete from public.matches where phase = 'league';
    update public.league_settings
       set season_started_at = null, updated_at = now() where id = 1;
  end if;

  return made;
end;
$$;

-- Reshuffle the fixtures. Only while nothing has been played, since a confirmed
-- result would otherwise lose the fixture it belongs to.
create or replace function public.admin_regenerate_schedule()
returns int language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if exists (select 1 from public.matches where status = 'confirmed') then
    raise exception 'Results have already been confirmed — the schedule is fixed now.'
      using errcode = 'P0001';
  end if;
  if (select phase from public.league_settings where id = 1) <> 'league' then
    raise exception 'The playoffs have started.' using errcode = 'P0001';
  end if;
  return public.generate_schedule();
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

-- Fixtures this team still has to play.
create or replace function public.fixtures_remaining(p_team uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.matches
   where phase = 'league' and status in ('scheduled','pending','disputed')
     and (team_a = p_team or team_b = p_team);
$$;

-- Records the result of a scheduled league fixture. Either team may enter it —
-- the other side still has to confirm before it counts, which is the real
-- safeguard — but the score is always stored from the fixture's own point of
-- view, never the submitter's.
create or replace function public.submit_league_result(
  p_match_id uuid, p_my_score int, p_opp_score int
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  me  uuid := public.current_team_id();
  cfg public.league_settings%rowtype;
  m   public.matches%rowtype;
begin
  if public.current_player_id() is null then
    raise exception 'Not signed in.' using errcode = 'P0001';
  end if;
  if me is null then
    raise exception 'You need a team before you can log a result.' using errcode = 'P0001';
  end if;

  select * into cfg from public.league_settings where id = 1;
  if cfg.phase <> 'league' then
    raise exception 'The league phase is closed — playoffs have started.' using errcode = 'P0001';
  end if;

  select * into m from public.matches where id = p_match_id for update;
  if not found or m.phase <> 'league' then
    raise exception 'That fixture does not exist.' using errcode = 'P0002';
  end if;
  if me not in (m.team_a, m.team_b) then
    raise exception 'That is not your fixture.' using errcode = 'P0001';
  end if;
  if m.status not in ('scheduled', 'disputed') then
    raise exception 'This fixture already has a result waiting.' using errcode = 'P0001';
  end if;

  if p_my_score is null or p_opp_score is null
     or p_my_score < 0 or p_opp_score < 0 or p_my_score > 99 or p_opp_score > 99 then
    raise exception 'Enter a valid score.' using errcode = 'P0001';
  end if;
  -- Level after extra time is a tie, and a tie is a legitimate league result.

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

-- Records a playoff result into an existing bracket slot. Either side may enter
-- it, as in the league; the opponent confirms.
create or replace function public.submit_playoff_result(
  p_match_id uuid, p_my_score int, p_opp_score int, p_shootout_winner uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_team_id(); m public.matches%rowtype; pens uuid;
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
  pens := public.check_playoff_score(
    m,
    case when me = m.team_a then p_my_score else p_opp_score end,
    case when me = m.team_a then p_opp_score else p_my_score end,
    p_shootout_winner);

  update public.matches
     set score_a      = case when me = team_a then p_my_score else p_opp_score end,
         score_b      = case when me = team_a then p_opp_score else p_my_score end,
         shootout_winner = pens,
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
         winner_id    = case when score_a > score_b then team_a
                             when score_b > score_a then team_b end,
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

  -- The fixture stays on the schedule either way; only the result is undone.
  update public.matches
     set status = 'scheduled', score_a = null, score_b = null, shootout_winner = null,
         submitted_by = null, updated_at = now()
   where id = p_match_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Bracket progression
-- ---------------------------------------------------------------------------

-- Playoff ties are two legs on aggregate, except the final, which is one game.
-- A tie is every playoff row sharing (round, slot).

-- The last round is the final.
create or replace function public.playoff_is_final(p_round int)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.matches where phase = 'playoff' and round > p_round);
$$;

-- Who has won a tie, or null while it is still being played. A bye is won the
-- moment it exists; a final by its one game; anything else on aggregate once
-- both legs are confirmed. Level either way goes to the shootout winner.
create or replace function public.tie_winner(p_round int, p_slot int)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare
  legs  int;
  done  int;
  agg_a int;
  agg_b int;
  ta    uuid;
  tb    uuid;
  bye   uuid;
  pens  uuid;
begin
  select count(*), count(*) filter (where status = 'confirmed'),
         sum(score_a) filter (where status = 'confirmed'),
         sum(score_b) filter (where status = 'confirmed'),
         max(team_a::text)::uuid, max(team_b::text)::uuid,
         max(winner_id::text) filter (where status = 'bye'),
         max(shootout_winner::text) filter (where status = 'confirmed')
    into legs, done, agg_a, agg_b, ta, tb, bye, pens
    from public.matches
   where phase = 'playoff' and round = p_round and slot = p_slot;

  if bye is not null then return bye; end if;
  if legs = 0 or done < legs then return null; end if;
  if agg_a > agg_b then return ta; end if;
  if agg_b > agg_a then return tb; end if;
  return pens;
end;
$$;

-- The rules for a playoff score, given from team_a's side, returning the
-- shootout winner to store. Penalties never change the score, so a game can
-- always end level. But whatever settles a tie — the final, or the second leg
-- to be played when the aggregate is level — then needs the shootout winner,
-- and it is ignored anywhere else. The second leg also waits for the first,
-- since the aggregate is not known until then.
create or replace function public.check_playoff_score(
  m public.matches, p_score_a int, p_score_b int, p_shootout_winner uuid
) returns uuid language plpgsql stable security definer set search_path = public as $$
declare other public.matches%rowtype; deciding_level boolean;
begin
  if m.status = 'bye' then
    raise exception 'That is a bye — there is nothing to play.' using errcode = 'P0001';
  end if;

  if public.playoff_is_final(m.round) then
    deciding_level := p_score_a = p_score_b;
  else
    select * into other from public.matches
     where phase = 'playoff' and round = m.round and slot = m.slot and leg <> m.leg;

    if m.leg = 2 and other.status is distinct from 'confirmed' then
      raise exception 'Play the first leg first — it has to be confirmed before the second.'
        using errcode = 'P0001';
    end if;

    deciding_level := other.status = 'confirmed'
      and other.score_a + p_score_a = other.score_b + p_score_b;
  end if;

  if not deciding_level then return null; end if;
  if p_shootout_winner is null or p_shootout_winner not in (m.team_a, m.team_b) then
    raise exception 'That leaves it level, so it goes to penalties — say who won the shootout. The score stays a tie.'
      using errcode = 'P0001';
  end if;
  return p_shootout_winner;
end;
$$;

-- Once both teams in a tie are known, the better seed is at home in the second
-- leg and in the final; the other team hosts the first leg.
create or replace function public.set_playoff_homes(p_round int, p_slot int)
returns void language plpgsql security definer set search_path = public as $$
declare better uuid; worse uuid; single boolean;
begin
  select case when seed_a <= seed_b then team_a else team_b end,
         case when seed_a <= seed_b then team_b else team_a end
    into better, worse
    from public.matches
   where phase = 'playoff' and round = p_round and slot = p_slot
     and team_a is not null and team_b is not null
   limit 1;
  if better is null then return; end if;

  single := public.playoff_is_final(p_round);
  update public.matches
     set home_team = case when single or leg = 2 then better else worse end
   where phase = 'playoff' and round = p_round and slot = p_slot;
end;
$$;

-- Advances a tie's winner into its parent slot, or crowns the champion if it
-- was the final. Does nothing while the tie is still being played.
create or replace function public.push_winner(p_match_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m public.matches%rowtype; w uuid; wseed int; parent_round int; parent_slot int;
begin
  select * into m from public.matches where id = p_match_id;
  if not found or m.phase <> 'playoff' then return; end if;

  w := public.tie_winner(m.round, m.slot);
  if w is null then return; end if;
  wseed := case when w = m.team_a then m.seed_a else m.seed_b end;
  parent_round := m.round + 1;
  parent_slot  := m.slot / 2;

  if not exists (select 1 from public.matches
                  where phase = 'playoff' and round = parent_round and slot = parent_slot) then
    update public.league_settings
       set champion_team_id = w, phase = 'complete', updated_at = now() where id = 1;
    return;
  end if;

  if m.slot % 2 = 0 then
    update public.matches set team_a = w, seed_a = wseed, updated_at = now()
     where phase = 'playoff' and round = parent_round and slot = parent_slot;
  else
    update public.matches set team_b = w, seed_b = wseed, updated_at = now()
     where phase = 'playoff' and round = parent_round and slot = parent_slot;
  end if;
  perform public.set_playoff_homes(parent_round, parent_slot);
end;
$$;

-- Wipes every downstream tie that descended from a match, used when an admin
-- voids or rewrites a result that may already have advanced somebody.
create or replace function public.clear_from(p_round int, p_slot int)
returns void language plpgsql security definer set search_path = public as $$
declare r int := p_round; s int := p_slot;
begin
  loop
    if not exists (select 1 from public.matches
                    where phase = 'playoff' and round = r + 1 and slot = s / 2) then
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
           home_team = null, shootout_winner = null,
           score_a = null, score_b = null, winner_id = null,
           status  = 'scheduled', submitted_by = null,
           confirmed_by = null, confirmed_at = null, updated_at = now()
     where phase = 'playoff' and round = r + 1 and slot = s / 2;

    r := r + 1; s := s / 2;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- League chat
-- ---------------------------------------------------------------------------

-- Writes (or rewrites) the automatic result line for a match.
create or replace function public.post_result_message(p_match_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m public.matches%rowtype; a text; b text; winner text; pens text;
begin
  select * into m from public.matches where id = p_match_id;
  if not found or m.status <> 'confirmed' then return; end if;
  select name into pens from public.teams where id = m.shootout_winner;

  select name into a from public.teams where id = m.team_a;
  select name into b from public.teams where id = m.team_b;
  winner := case when m.winner_id = m.team_a then a when m.winner_id = m.team_b then b end;

  insert into public.messages (kind, body, team_name, match_id)
  values ('result',
          coalesce(a, 'Unknown') || ' ' || m.score_a || '–' || m.score_b || ' ' || coalesce(b, 'Unknown')
            || coalesce(' · ' || pens || ' win on penalties', ''),
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
          or old.score_b is distinct from new.score_b
          or old.shootout_winner is distinct from new.shootout_winner) then
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
  if p_games_per_team is null or p_games_per_team < 2 or p_games_per_team > 200
     or p_games_per_team % 2 <> 0 then
    raise exception 'Games per team has to be an even number from 2 to 200 — you play each opponent twice.'
      using errcode = 'P0001';
  end if;
  if p_playoff_size is not null and p_playoff_size not between 2 and 64 then
    raise exception 'Playoffs need between 2 and 64 teams.' using errcode = 'P0001';
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

-- Locks the league and builds the whole bracket in one shot. Everyone makes the
-- playoffs. The bracket is sized up to the next power of two and the spare
-- places go to the top seeds as first-round byes — with seven teams, that is
-- one bye, for the #1 seed. Every tie is two legs on aggregate except the
-- final, which is one game.
create or replace function public.admin_start_playoffs()
returns void language plpgsql security definer set search_path = public as $$
declare
  cfg          public.league_settings%rowtype;
  qualifiers   uuid[];
  order_seeds  int[] := array[1];
  grown        int[];
  n            int;
  size         int := 1;
  total_rounds int := 0;
  sa int; sb int;
  i int; r int; s int;
  bye_id uuid;
begin
  perform public.assert_admin();
  select * into cfg from public.league_settings where id = 1;
  if cfg.phase <> 'league' then
    raise exception 'The playoffs have already started.' using errcode = 'P0001';
  end if;

  select count(*) into n from public.teams where is_active;
  if n < 2 then
    raise exception 'Need at least 2 teams for a playoff — there are %.', n using errcode = 'P0001';
  end if;
  if n > 64 then
    raise exception 'The bracket tops out at 64 teams — there are %.', n using errcode = 'P0001';
  end if;

  while size < n loop size := size * 2; total_rounds := total_rounds + 1; end loop;

  -- Standard bracket order (1v8, 4v5, 2v7, 3v6 …), so the top two seeds can
  -- only meet in the final. Built by doubling: each seed k is joined by the
  -- seed that sums with it to one more than the new size.
  while array_length(order_seeds, 1) < size loop
    grown := '{}';
    foreach sa in array order_seeds loop
      grown := grown || sa || (array_length(order_seeds, 1) * 2 + 1 - sa);
    end loop;
    order_seeds := grown;
  end loop;

  select array_agg(team_id order by rank) into qualifiers from public.standings;

  -- Anything unplayed or unconfirmed can no longer affect seeding.
  update public.matches
     set status = 'voided', admin_note = 'Voided automatically when the playoffs started.',
         updated_at = now()
   where phase = 'league' and status in ('scheduled','pending','disputed');

  delete from public.matches where phase = 'playoff';

  -- Round 1 gets real teams, or a bye where the lower seed does not exist.
  for i in 0 .. (size / 2 - 1) loop
    sa := order_seeds[i * 2 + 1];
    sb := order_seeds[i * 2 + 2];
    if sb > n then
      insert into public.matches (phase, round, slot, leg, team_a, seed_a, winner_id, status)
      values ('playoff', 1, i, 1, qualifiers[sa], sa, qualifiers[sa], 'bye');
    else
      insert into public.matches (phase, round, slot, leg, team_a, team_b, seed_a, seed_b, status)
      select 'playoff', 1, i, leg, qualifiers[sa], qualifiers[sb], sa, sb, 'scheduled'
        from generate_series(1, case when total_rounds = 1 then 1 else 2 end) as g(leg);
    end if;
  end loop;

  -- Later rounds are empty ties the trigger fills in; the final is one game.
  for r in 2 .. total_rounds loop
    for s in 0 .. (size / (2 ^ r)::int - 1) loop
      insert into public.matches (phase, round, slot, leg, status)
      select 'playoff', r, s, leg, 'scheduled'
        from generate_series(1, case when r = total_rounds then 1 else 2 end) as g(leg);
    end loop;
  end loop;

  -- Only now that the whole bracket exists can a tie tell whether it is the final.
  for i in 0 .. (size / 2 - 1) loop
    perform public.set_playoff_homes(1, i);
  end loop;

  -- Byes go straight through.
  for bye_id in select id from public.matches where phase = 'playoff' and status = 'bye' loop
    perform public.push_winner(bye_id);
  end loop;

  update public.league_settings
     set phase = 'playoffs', playoff_size = n,
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
  p_match_id uuid, p_score_a int, p_score_b int, p_note text default null,
  p_shootout_winner uuid default null
) returns void language plpgsql security definer set search_path = public as $$
declare m public.matches%rowtype; pens uuid;
begin
  perform public.assert_admin();
  select * into m from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found.' using errcode = 'P0002'; end if;
  if p_score_a is null or p_score_b is null
     or p_score_a < 0 or p_score_b < 0 or p_score_a > 99 or p_score_b > 99 then
    raise exception 'Enter a valid score.' using errcode = 'P0001';
  end if;
  if m.phase = 'playoff' then
    if m.team_a is null or m.team_b is null then
      raise exception 'This matchup is still waiting on an earlier round.' using errcode = 'P0001';
    end if;
    pens := public.check_playoff_score(m, p_score_a, p_score_b, p_shootout_winner);
  end if;

  if m.phase = 'playoff' and m.status = 'confirmed' then
    perform public.clear_from(m.round, m.slot);
  end if;

  update public.matches
     set score_a = p_score_a, score_b = p_score_b, status = 'confirmed',
         shootout_winner = pens,
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
  if m.status = 'bye' then
    raise exception 'That is a bye — there is nothing to void.' using errcode = 'P0001';
  end if;

  if m.phase = 'playoff' then
    if m.status = 'confirmed' then perform public.clear_from(m.round, m.slot); end if;
    update public.matches
       set status = 'scheduled', score_a = null, score_b = null, winner_id = null,
           shootout_winner = null,
           submitted_by = null, confirmed_by = null, confirmed_at = null,
           admin_note = p_note, updated_at = now()
     where id = p_match_id;
  else
    -- League fixtures go back on the schedule to be replayed, rather than
    -- vanishing from a season everybody is counting games against.
    update public.matches
       set status = 'scheduled', score_a = null, score_b = null, winner_id = null,
           shootout_winner = null,
           submitted_by = null, confirmed_by = null, confirmed_at = null,
           admin_note = p_note, updated_at = now()
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
  public.fixtures_remaining(uuid),
  public.submit_league_result(uuid, int, int),
  public.submit_playoff_result(uuid, int, int, uuid),
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
  public.admin_regenerate_schedule(),
  public.admin_start_playoffs(),
  public.admin_reset_playoffs(),
  public.admin_resolve_match(uuid, int, int, text, uuid),
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
-- 3. Rebuild an unplayed schedule in the weekly format
-- ---------------------------------------------------------------------------

do $$
declare made int;
begin
  if (select season_started_at is not null and phase = 'league'
        from public.league_settings where id = 1)
     and not exists (select 1 from public.matches where status = 'confirmed') then
    made := public.generate_schedule();
    raise notice 'Nothing had been played yet, so the schedule was rebuilt: % games.', made;
  elsif exists (select 1 from public.matches where phase = 'league' and status = 'confirmed') then
    raise notice 'Results already exist, so the current schedule was kept as it is.';
  end if;
end $$;

commit;

do $$
begin
  raise notice '=================================================';
  raise notice ' Migration 003 complete — the league rules are in.';
  raise notice '=================================================';
end $$;
