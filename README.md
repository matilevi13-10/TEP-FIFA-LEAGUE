# TEP FIFA League

A 2v2 FIFA league tracker for one private group. Teams of two, $50 a team, winner
of the playoff bracket takes the pot. Built to be used from a phone, on the couch,
mid-argument about whether that goal counted.

- **Phase 1 — League.** Every team plays a set number of games. Win 3, draw 1,
  loss 0. Sorted on points, then goal difference, then goals scored.
- **Phase 2 — Playoffs.** The admin locks the league and seeds the top 4, 8 or 16
  into a single-elimination bracket. No draws. Whoever wins the final takes the pot.
- **Every result needs two signatures.** The winning team submits (either team on a
  draw), the opponent confirms. Nothing touches the table or the bracket until it is
  confirmed. Anything disputed parks itself for the admin.

Stack: React + Vite on AWS Amplify, Supabase (free tier) for data, auth and realtime.

---

## Setup

### 1. Create the Supabase project

Make a project at [supabase.com](https://supabase.com). Free tier is plenty.

### 2. Run the schema

Open **SQL Editor → New query**, paste all of [`supabase/schema.sql`](supabase/schema.sql),
and run it. It creates the tables, row level security, the standings view, the bracket
engine, and every RPC the app calls. It also seeds:

- the league settings row (12 games, $50 buy-in)
- one admin login — **team `Admin`, PIN `1234`**

Re-running the file resets everything. It drops its own tables first.

### 3. Turn off email confirmation

**Authentication → Sign In / Providers → Email** and switch **Confirm email** off.

This is the one manual toggle and the app will not work without it. Players sign in
with a team and a 4-digit PIN; behind the scenes the app creates a Supabase auth user
per team on first login, and a confirmation email nobody can receive would block it.
Make sure **Allow new users to sign up** stays on.

### 4. Point the app at the project

**Project Settings → API**, then:

```bash
cp .env.example .env
```

Fill in `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`. Both are safe in the browser
bundle — the anon key only unlocks what row level security allows.

```bash
npm install
npm run dev
```

Sign in as `Admin` / `1234`. **Change that PIN immediately** (Admin → Teams → Admin →
Edit → Reset PIN), then add the real teams.

---

## Deploying to AWS Amplify

1. Connect the repo in the Amplify console. It will pick up
   [`amplify.yml`](amplify.yml) automatically.
2. **App settings → Environment variables** — add `VITE_SUPABASE_URL` and
   `VITE_SUPABASE_ANON_KEY`. Vite bakes these in at build time, so a change needs a
   redeploy.
3. **App settings → Rewrites and redirects** — add:

   | Source | Target | Type |
   | --- | --- | --- |
   | `/<*>` | `/index.html` | `200 (Rewrite)` |

   Skip this and the app works until someone reloads on `/table` and gets a 404. It is
   the usual way a single-page app breaks on Amplify.

Tell everyone to open the URL on their phone and **Add to Home Screen** — there is a
web manifest and icons, so it opens fullscreen like an app.

---

## How it hangs together

### Signing in

Players pick their team and type a 4-digit PIN. The PIN is never the password.

`begin_signin` checks the PIN against a bcrypt hash in `team_secrets` — a table with
row level security on and no policies, so nothing but a `SECURITY DEFINER` function can
read it. Only on a match does it hand back the team's actual Supabase credentials (a
32-byte random key). Eight wrong PINs locks that team out for fifteen minutes.

So guessing a PIN means going through the rate limiter, and a signed-in player still
cannot read anyone else's hash.

### Writes

The client never writes to a table. `matches`, `teams` and `league_settings` are
readable by any signed-in player and writable by nobody. Everything goes through RPCs
that enforce the rules server-side: the losing team cannot submit, you cannot confirm
your own result, playoff games cannot end level, nobody plays more games than the
season allows, and the league locks the moment the playoffs start.

### The bracket

`admin_start_playoffs` builds the whole bracket at once — round one gets the real
seedings (1v8, 4v5, 3v6, 2v7, so the top two can only meet in the final), later rounds
get empty slots. A trigger advances each confirmed winner into its parent slot and
crowns the champion when the final lands. If the admin voids or rewrites a result that
had already advanced somebody, `clear_from` walks up the bracket and wipes everything
downstream of it.

### Live updates

Every phone subscribes to `matches`, `teams` and `league_settings` over Supabase
realtime. A confirmed result re-renders the table on everyone's screen in about a
second. Standings are also recomputed client-side from the same rules as the
`standings` view, so the UI never waits on a round trip.

---

## Testing the schema

The SQL is covered by a suite that runs against a throwaway local Postgres:

```bash
brew install postgresql@16
./supabase/tests/run.sh
```

It plays a full season — sign-ins, wrong PINs, lockouts, submissions, confirmations,
disputes, admin resolutions, an 8-team bracket through to a champion, voiding a
confirmed semi-final and watching the bracket rebuild — and asserts row level security
actually holds for a normal player.

---

## Layout

```
src/
  lib/        supabase client, auth, realtime league store, RPC wrappers
  components/ logo, nav, toasts, score stepper, confirm button, icons
  screens/    SignIn, Home, Table, Submit, Bracket, Admin
  index.css   the whole design system, documented at the top
supabase/
  schema.sql  tables, RLS, RPCs, bracket engine, seed
  tests/      run.sh + the SQL suite
amplify.yml   build config
```

## Notes

- **Admin rights** live on a team row. The seeded `Admin` login does not play — it is
  excluded from the table, the pot and every opponent list. If you would rather run the
  league from your own team, open Admin → Teams → your team → **Make admin**, then
  deactivate the `Admin` login.
- **Buy-in tracking** is a paid/unpaid flag per team on the admin screen. The pot is
  simply active teams × buy-in.
- **PP Neue Montreal** is a commercial typeface from Pangram Pangram, bundled here in
  `src/fonts/`. Make sure your licence covers web use before this goes anywhere public.
