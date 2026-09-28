-- ============================================================================
-- TEP FIFA LEAGUE — migration 002: accounts, teams, chat, fixtures
--
-- One cumulative migration from the original schema (teams shared a PIN to log
-- in) to the current one:
--   • People sign up with email + password + a username. Supabase Auth owns the
--     credentials; this schema owns the username and who the admin is. A trigger
--     on auth.users creates the profile, so a signed-in account always has one.
--   • Whoever signs up with league_settings.admin_email gets the admin controls.
--   • Teams form by mutual consent: one unteamed player asks another, the team
--     exists when they accept. Nothing can create a player but signing up.
--   • Either teammate can rename the team, or leave it before the season starts.
--   • No draws — every confirmed result has a winner.
--   • Starting the season generates the league fixtures. Scores are entered
--     against a fixture, not a freely chosen opponent.
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
--   • Placeholder players with no team are removed; any sitting ON a team are
--     reported and left alone for you to decide about.
--   • Confirmed draws are voided (scores kept) so they stop counting.
--   • Unconfirmed league results go back on the schedule as fixtures.
--
-- AFTER RUNNING THIS, in the Supabase dashboard:
--   Authentication → Sign In / Providers → Email
--     • Confirm email:            OFF   (required — accounts must work at once)
--     • Allow new users to sign up: ON
--
-- FROZEN — this was generated from an earlier schema.sql. Run it, then run
-- 003_league_rules.sql. Schema changes go into 003 via build_003.py.
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
-- 2d. League matches are now fixtures on a generated schedule
-- ---------------------------------------------------------------------------

-- Previously a league match sprang into existence when somebody submitted a
-- score. Now the schedule is generated up front and results are entered against
-- it, so a league row can legitimately exist with no score yet.
--
-- Anything already played keeps its result. Unplayed league rows — a submission
-- that was never confirmed — go back to 'scheduled' so they sit on the schedule
-- like any other fixture rather than dangling.
do $$
declare n int;
begin
  update public.matches
     set status = 'scheduled', score_a = null, score_b = null,
         submitted_by = null, updated_at = now()
   where phase = 'league' and status in ('pending', 'disputed');
  get diagnostics n = row_count;
  if n > 0 then
    raise notice '% unconfirmed league result(s) returned to the schedule.', n;
  end if;

  -- Existing league matches predate rounds; number them so the schedule views
  -- have something sane to group by.
  if exists (select 1 from public.matches where phase = 'league' and round is null) then
    with numbered as (
      select id, row_number() over (order by created_at) as rn
        from public.matches where phase = 'league' and round is null
    )
    update public.matches m
       set round = numbered.rn, slot = 0
      from numbered where numbered.id = m.id;
    raise notice 'Existing league matches were given round numbers.';
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
-- submit_league_result took an opponent; it now takes a fixture id, and the
-- parameter rename means the old signature has to go rather than be replaced.
drop function if exists public.submit_league_result(uuid, int, int);
drop function if exists public.games_played(uuid);
drop function if exists public.admin_set_season_started(boolean);
drop function if exists public.admin_create_placeholder(text);

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
-- The league is played to a generated schedule rather than ad hoc. Everyone
-- plays everyone once before anyone plays anyone twice, which falls out of
-- building the schedule as repeated round-robin cycles.
-- ---------------------------------------------------------------------------

-- Builds the league schedule for the active teams and returns how many fixtures
-- it made. Wipes any existing league fixtures first, so it doubles as regenerate.
--
-- Method: the circle method gives one cycle in which every team meets every
-- other exactly once (with a bye each if the count is odd). Cycles are laid down
-- back to back, each independently shuffled, and a pairing is skipped once
-- either side already has its full allocation of games. That caps everyone at
-- games_per_team without anyone meeting the same opponent twice while a first
-- meeting is still outstanding.
create or replace function public.generate_schedule()
returns int language plpgsql security definer set search_path = public as $$
declare
  ids       uuid[];
  n         int;
  slots     int;
  target    int;
  arr       int[];
  played    int[];
  round_no  int := 0;
  slot_no   int;
  made      int := 0;
  cycle     int;
  r         int;
  i         int;
  a         int;
  b         int;
  emitted   boolean;
  carry     int;
begin
  delete from public.matches where phase = 'league';

  select array_agg(id order by random()) into ids
    from public.teams where is_active;
  n := coalesce(array_length(ids, 1), 0);
  if n < 2 then return 0; end if;

  select games_per_team into target from public.league_settings where id = 1;
  -- Nobody can play more games than there are opponents-times-cycles we build,
  -- but the cap below keeps a silly setting from looping forever.
  target := least(target, (n - 1) * 20);

  played := array_fill(0, array[n]);
  -- An odd count gets a phantom slot; whoever draws it sits that round out.
  slots := case when n % 2 = 0 then n else n + 1 end;

  for cycle in 1 .. greatest(1, target) loop
    -- Fresh shuffle each cycle so repeat meetings do not follow the same order.
    select array_agg(x order by random()) into arr
      from generate_series(1, slots) as g(x);

    for r in 1 .. slots - 1 loop
      emitted := false;
      slot_no := 0;

      for i in 1 .. slots / 2 loop
        a := arr[i];
        b := arr[slots + 1 - i];
        -- Skip the phantom, and skip anyone who already has a full card.
        if a <= n and b <= n and played[a] < target and played[b] < target then
          insert into public.matches (phase, round, slot, team_a, team_b, status)
          values ('league', round_no + 1, slot_no, ids[a], ids[b], 'scheduled');
          played[a] := played[a] + 1;
          played[b] := played[b] + 1;
          slot_no := slot_no + 1;
          made := made + 1;
          emitted := true;
        end if;
      end loop;

      if emitted then round_no := round_no + 1; end if;

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
  if p_my_score = p_opp_score then
    raise exception 'Games cannot end level — play it out until somebody wins.'
      using errcode = 'P0001';
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

  -- The fixture stays on the schedule either way; only the result is undone.
  update public.matches
     set status = 'scheduled', score_a = null, score_b = null,
         submitted_by = null, updated_at = now()
   where id = p_match_id;
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

  -- Anything unplayed or unconfirmed can no longer affect seeding.
  update public.matches
     set status = 'voided', admin_note = 'Voided automatically when the playoffs started.',
         updated_at = now()
   where phase = 'league' and status in ('scheduled','pending','disputed');

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
    -- League fixtures go back on the schedule to be replayed, rather than
    -- vanishing from a season everybody is counting games against.
    update public.matches
       set status = 'scheduled', score_a = null, score_b = null, winner_id = null,
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
  public.admin_regenerate_schedule(),
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
