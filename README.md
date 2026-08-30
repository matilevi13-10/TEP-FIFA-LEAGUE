# TEP FIFA League

A 2v2 FIFA league tracker for one private group. Teams of two, $50 a team, winner
of the playoff bracket takes the pot. Built to be used from a phone, on the couch,
mid-argument about whether that goal counted.

- **Phase 1 — League.** Every team plays a set number of games. **Win 3, loss 0 —
  there are no draws.** A level score cannot be submitted, cannot be settled by an
  admin, and cannot exist as a confirmed row in the database. Sorted on points,
  then goal difference, then goals scored. The table is the home page.
- **Phase 2 — Playoffs.** The admin locks the league and seeds the top 4, 8 or 16
  into a single-elimination bracket. Whoever wins the final takes the pot.
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

**Already running an older version:** run
[`supabase/migrations/002_accounts_and_chat.sql`](supabase/migrations/002_accounts_and_chat.sql)
instead. It is additive, wrapped in a transaction and re-runnable, and it keeps
your teams, matches and season.

### 3. Two dashboard settings

**Authentication → Sign In / Providers → Email**

| Setting | Value | Why |
| --- | --- | --- |
| **Confirm email** | **OFF** | Accounts have to work the moment someone signs up. Leave this on and nobody can get in. |
| **Allow new users to sign up** | **ON** | Players create their own accounts. |

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

A signed-in account always has a profile. If one is ever missing — a sign-up
interrupted halfway, or a login predating this schema — `ensure_account()`
creates it from the email address on the next load, so "signed in but not set up"
is not a state the app can get stuck in. An account with no team simply sees the
league table and the Add Team form.

Whoever signs up with the address in `league_settings.admin_email`
(**matilevi13@gmail.com** by default) gets the admin controls automatically. You
can hand that over from Admin → Season.

### Teams

One person creates the team and names the other half. The teammate is either an
existing account, picked from a list, or a **placeholder** — just a name. When
that person signs up under exactly that username, they claim the placeholder and
land on the team already built for them. Everyone is on at most one team.

The admin can also pair two people directly, or dissolve a team, as a fallback.

### Writes

The client never writes to a table. `teams`, `players`, `matches`, `messages` and
`league_settings` are readable by any signed-in player and writable by nobody.
Everything goes through `SECURITY DEFINER` RPCs that enforce the rules
server-side: the losing team cannot submit, you cannot confirm your own result,
playoff games cannot end level, nobody plays more games than the season allows,
and the league locks the moment the playoffs start.

### The bracket

`admin_start_playoffs` builds the whole bracket at once — round one gets the real
seedings (1v8, 4v5, 3v6, 2v7, so the top two can only meet in the final), later
rounds get empty slots. A trigger advances each confirmed winner into its parent
slot and crowns the champion when the final lands. If the admin voids or rewrites
a result that had already advanced somebody, `clear_from` walks up the bracket and
wipes everything downstream of it.

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
creation, submissions, confirmations, disputes, admin resolutions, an 8-team
bracket through to a champion, voiding a confirmed semi-final and watching the
bracket rebuild, chat, taunts — and asserts row level security actually holds for
a normal player.

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

`supabase/migrations/002_accounts_and_chat.sql` is generated from `schema.sql` so
the two cannot drift. After editing the schema, run
`python3 supabase/migrations/build_002.py`.

## Notes

- **Anyone with the URL can sign up.** That is what "no confirmation email" buys.
  For a private group it is usually fine; the admin can delete stray accounts from
  Admin → Players.
- **Passwords** are Supabase Auth's business. There is no password reset inside
  the app — use the Supabase dashboard if someone is locked out.
- **PP Neue Montreal** is a commercial typeface from Pangram Pangram, bundled here
  in `src/fonts/`. Make sure your licence covers web use before this goes anywhere
  public.
