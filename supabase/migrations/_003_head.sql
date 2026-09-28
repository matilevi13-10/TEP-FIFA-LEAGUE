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
