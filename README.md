# TEP FIFA League

A 2v2 FIFA league tracker for one private group. Teams of two, $50 a team, winner
of the playoff bracket takes the pot. Built to be used from a phone, on the couch,
mid-argument about whether that goal counted.

- **Phase 1 — League.** Starting the season generates the fixtures in rounds,
  one a week: each round is one opponent, played twice that week, one home game
  each. Games per team (an admin setting, always even) sets the length — 12
  games is 6 rounds, which with seven teams is everyone once over seven weeks,
  each team sitting one week out. The home team picks their team and the console. Each team sees its Next
  Match and enters the score against that fixture — there is no free-form match
  creation. **Win 3, draw 1, loss 0** — a game still level after classic extra
  time is a tie. Sorted on points, then goal difference, then goals scored. The
  table is the home page.
- **Phase 2 — Playoffs.** Everyone makes it. The admin locks the league and
  seeds every team into a bracket rounded up to a power of two; the spare
  places are first-round byes for the top seeds (with seven teams, just #1).
  Ties are two legs on aggregate, the higher seed at home in the second leg;
  the final is one game. Penalties never count toward the score: a level final
  or aggregate stays a tie on the scoresheet, and the shootout winner is
  recorded separately to decide who goes through. Whoever wins the final takes
  the pot.
- **The rules** are on the home page under the table.
- **Every result needs two signatures.** The winning team submits, the opponent
  confirms. Nothing touches the table or the bracket until it is
  confirmed. Anything disputed parks itself for the admin.
- **A league chat.** One room, everyone in it. Confirmed results announce
  themselves, and the winning team gets one taunt per win.

Stack: React + Vite on AWS Amplify, Supabase (free tier) for data, auth and realtime.

---

## Setup

### 1. Create the Supabase project

Make a project at [supabase.com](https://supabase.com). Free tier is plenty.

### 2. Run the SQL

**New project:** paste all of [`supabase/schema.sql`](supabase/schema.sql) into
**SQL Editor → New query** and run it.

**Already running an older version:** run the migrations you have not run yet,
in order, instead:

1. [`002_accounts_and_chat.sql`](supabase/migrations/002_accounts_and_chat.sql) —
   only if you are still on the original team-PIN schema.
2. [`003_league_rules.sql`](supabase/migrations/003_league_rules.sql) — the
   weekly rounds, ties, shootouts, and the everyone-qualifies playoffs.

Both are additive, wrapped in a transaction and re-runnable, and keep your
teams, matches and season. 003 rebuilds the schedule in the weekly format only
if the season has started and nothing has been confirmed yet.

**Run the SQL before deploying the app.** The app expects the new columns and
functions, so a deploy that lands before the migration will misbehave.

### 3. Two dashboard settings

**Authentication → Sign In / Providers → Email**

| Setting | Value | Why |
| --- | --- | --- |
| **Confirm email** | **OFF** | Accounts have to work the moment someone signs up. Leave this on and nobody can get in. |
| **Allow new users to sign up** | **ON** | Players create their own accounts. |

If sign-in ever reports that it can't load your profile, the message names the
cause. "The database is missing its setup" means the migration in step 2 has not
been run.

Nothing else. No Google, no Apple, no OAuth.

### 4. Point the app at the project

**Project Settings → API**, then:

```bash
cp .env.example .env      # fill in the URL and anon key
npm install
npm run dev
```

Sign up with the admin address (see below) and you'll have the admin controls.

---

## How it hangs together

### Accounts

Supabase Auth owns the email and password. This schema owns the **username**,
which is the identity everyone actually sees — in the table, the chat, and on a
team. Sign-up is username + email + password; sign-in is email + password. That
is the whole of it: no OAuth, no codes, no second factor.

**A signed-in account always has a profile.** A trigger on `auth.users` creates
it the moment Supabase Auth creates the account, using the username passed as
sign-up metadata, so the client never has to make it. The trigger claims a
waiting placeholder if one matches the username, keeping that team.

The trigger is deliberately unable to fail loudly: an exception inside it would
roll back the auth user and break sign-up altogether, so it warns and lets
`ensure_account()` repair the row on first load instead. That same function
covers accounts created before the trigger existed. Both go through one shared
core (`attach_player`) so the paths cannot drift apart.

An account with no team is a normal state — it sees the league table and the Add
Team form, never an error.

Whoever signs up with the address in `league_settings.admin_email`
(**matilevi13@gmail.com** by default) gets the admin controls automatically. You
can hand that over from Admin → Season.

### Teams

A team is formed by mutual consent and no other way. Everyone without a team
sits in the **Player Pool**; any of them can send a teammate request to another
unteamed player, optionally proposing a name. The recipient accepts or declines,
and the team exists the moment they accept — appearing in the table immediately.

Typing a name can never bring a player into existence: the only way to become a
player is to sign yourself up. One live outgoing request per person, cancellable
at any time, and requests auto-expire once either side joins a team.

Either teammate can rename their team at any point, from their team view. Names
stay unique, and a rename shows up everywhere at once.

**Before the season starts**, either teammate can also leave. Leaving dissolves
the team outright rather than stranding somebody in a team of one: both players
return to the pool, the name is freed, and old requests stay expired so everyone
starts fresh. The option disappears the moment the season starts.

"Started" means the admin opened it (Admin → Season state), the playoffs began,
or any result has been confirmed — that last one matters so an admin who forgets
to press the button cannot leave a played team dissolvable.

The admin can pair two unteamed players directly, or dissolve a team, as a
fallback.

### Writes

The client never writes to a table. `teams`, `players`, `matches`, `messages` and
`league_settings` are readable by any signed-in player and writable by nobody.
Everything goes through `SECURITY DEFINER` RPCs that enforce the rules
server-side: you cannot confirm your own result, a level playoff final or
aggregate needs a shootout winner, a second leg waits for the first, and the
league locks the moment the playoffs start.

### The bracket

`admin_start_playoffs` builds the whole bracket at once — round one gets the real
seedings (1v8, 4v5, 3v6, 2v7, so the top two can only meet in the final), with a
`bye` row wherever the lower seed does not exist, and later rounds get empty
slots. Each tie is two rows (`leg` 1 and 2) sharing a `(round, slot)`; the final
is one. Once both legs are confirmed, a trigger advances the aggregate winner
into its parent slot, and the final crowns the champion. If the admin voids or
rewrites a result that had already advanced somebody, `clear_from` walks up the
bracket and wipes everything downstream of it.

### Chat, results and taunts

Confirming a match posts an automatic result line, styled as the league talking
rather than a player. Correct a score and the line rewrites itself; void the match
and it disappears, taking any taunt with it. The winning team gets a one-shot
taunt prompt — winner only, once per match, both enforced in the database.

### Live updates

Every phone subscribes to `matches`, `teams`, `players`, `messages` and
`league_settings` over Supabase realtime. A confirmed result re-renders the table
on everyone's screen in about a second. Standings are also recomputed
client-side from the same rules as the `standings` view, so the UI never waits on
a round trip.

---

## Testing the schema

The SQL is covered by a suite that runs against a throwaway local Postgres:

```bash
brew install postgresql@16
./supabase/tests/run.sh
```

It plays a full season — sign-ups, username collisions, placeholder claims, team
creation, the weekly schedule, submissions, ties, confirmations, disputes, admin
resolutions, a 7-team bracket with a bye through two-leg ties to a champion,
voiding a semi-final leg and watching the bracket rebuild, chat, taunts — and
asserts row level security actually holds for a normal player.

To check the migration lands in the same place as a fresh install, the suite is
also run against a migrated database during development.

---

## Layout

```
src/
  lib/        supabase client, auth, realtime league store, RPC wrappers
  components/ logo, nav, chat, taunt prompt, add-team form, toasts, icons
  screens/    SignIn, Home (table + your team), Teams, Submit, Bracket, Admin
  index.css   the whole design system, documented at the top
supabase/
  schema.sql              fresh install
  migrations/             generated migration + its head/tail sources
  tests/                  run.sh + the SQL suite
amplify.yml   build config
```

`supabase/migrations/003_league_rules.sql` is generated from `schema.sql` so
the two cannot drift. After editing the schema, run
`python3 supabase/migrations/build_003.py`. `002` is frozen: its structure
section predates 003, so it is no longer regenerated.

## Notes

- **Anyone with the URL can sign up.** That is what "no confirmation email" buys.
  For a private group it is usually fine; the admin can delete stray accounts from
  Admin → Players.
- **Passwords** are Supabase Auth's business. There is no password reset inside
  the app — use the Supabase dashboard if someone is locked out.
- **Typography is the system font** — SF Pro on Apple hardware, the platform's own
  face elsewhere. It ships optical sizing and tracking tables that a webfont
  can't match, and it costs nothing to download. The PP Neue Montreal files that
  used to be in `src/fonts/` were removed; recover them with
  `git checkout <earlier-commit> -- src/fonts` if you want them back.
- **The design system lives at the top of `src/index.css`** — one spacing scale,
  one type scale, one radius scale, one shadow scale, and spring curves sampled
  from Apple's damping/response model. A component that needs a value not on a
  scale means the scale is wrong; fix it there, not locally.
