import { useEffect, useState } from 'react'
import { useAuth } from '../lib/auth'
import { describeSeason, fixtureLabel, needsShootout, useLeague } from '../lib/league'
import {
  adminCreateTeam, adminDeleteMessage, adminDeletePlayer, adminRegenerateSchedule, adminSetSeasonStarted,
  adminDissolveTeam, adminRenamePlayer, adminResetPlayoffs, adminResolveMatch,
  adminStartPlayoffs, adminUpdateSettings, adminUpdateTeam, adminVoidMatch,
} from '../lib/actions'
import { ConfirmButton } from '../components/ConfirmButton'
import { useToast } from '../components/Toast'
import { readableError } from '../lib/supabase'
import { haptic, money, timeAgo } from '../lib/format'
import type { Match, Player, Team } from '../lib/types'

type Run = (work: () => Promise<unknown>, message: string) => Promise<boolean>

export function Admin() {
  const { player } = useAuth()
  const league = useLeague()
  const toast = useToast()

  if (!player?.is_admin) {
    return (
      <div className="page">
        <div className="section card center muted" style={{ padding: 'var(--s-8)' }}>Admins only.</div>
      </div>
    )
  }

  const run: Run = async (work, message) => {
    try {
      await work()
      haptic([10, 30, 10])
      toast(message, 'good')
      await league.refresh()
      return true
    } catch (cause) {
      toast(readableError(cause), 'bad')
      return false
    }
  }

  return (
    <div className="page">
      <div className="section" style={{ marginBottom: 'var(--s-5)' }}>
        <h1 className="t-title" style={{ margin: 0 }}>Admin</h1>
        <div className="t-foot dim">
          {league.settings?.season_name} · {league.activeTeams.length} teams ·{' '}
          {league.pool.length} in the pool · pot {money(league.potCents)}
        </div>
      </div>

      {league.schemaOutdated && (
        <section className="section">
          <div className="card card--accent" role="alert">
            <div className="t-headline" style={{ color: 'var(--danger)' }}>The database needs updating</div>
            <p className="t-foot muted" style={{ margin: 'var(--s-2) 0 0' }}>
              It is still running the old league code, so schedules, ties and the playoffs
              will come out wrong. In Supabase, open SQL Editor → New query, paste all of{' '}
              <code>supabase/migrations/003_league_rules.sql</code> and run it. If nothing has
              been played yet it rebuilds the schedule for you.
            </p>
          </div>
        </section>
      )}

      <NeedsAttention run={run} />
      <SeasonState run={run} />
      <SeasonSettings run={run} />
      <Playoffs run={run} />
      <TeamsAdmin run={run} />
      <PlayersAdmin run={run} />
      <ChatModeration run={run} />
    </div>
  )
}

// ── Disputes and pending results ──────────────────────────────────────────

function NeedsAttention({ run }: { run: Run }) {
  const league = useLeague()
  const flagged = league.matches.filter((m) => m.status === 'disputed')
  const waiting = league.matches.filter((m) => m.status === 'pending')
  if (flagged.length === 0 && waiting.length === 0) return null

  return (
    <section className="section">
      <div className={`eyebrow${flagged.length ? ' eyebrow--accent' : ''}`}>
        {flagged.length > 0 ? `${flagged.length} disputed` : `${waiting.length} awaiting confirmation`}
      </div>
      <div className="stack">
        {[...flagged, ...waiting].map((match) => <MatchRow key={match.id} match={match} run={run} />)}
      </div>
    </section>
  )
}

function MatchRow({ match, run }: { match: Match; run: Run }) {
  const league = useLeague()
  const [scoreA, setScoreA] = useState(match.score_a ?? 0)
  const [scoreB, setScoreB] = useState(match.score_b ?? 0)
  const [pens, setPens] = useState<string | null>(match.shootout_winner)
  const [busy, setBusy] = useState(false)

  const teamA = league.teamById(match.team_a)
  const teamB = league.teamById(match.team_b)
  const submitter = league.teamById(match.submitted_by)
  const shootout = needsShootout(match, league.matches, scoreA, scoreB)

  const act = async (work: () => Promise<unknown>, message: string) => {
    setBusy(true); await run(work, message); setBusy(false)
  }

  return (
    <div className="card">
      <div className="spread" style={{ marginBottom: 'var(--s-3)' }}>
        <div style={{ minWidth: 0 }}>
          <div className="t-headline">{teamA?.name ?? '—'} vs {teamB?.name ?? '—'}</div>
          <div className="t-caption dim">
            {fixtureLabel(match, league.matches)} · sent by {submitter?.name ?? 'unknown'} ·{' '}
            {timeAgo(match.created_at)}
          </div>
        </div>
        <span className={`pill${match.status === 'disputed' ? ' pill--accent' : ''}`}>
          {match.status === 'disputed' ? 'Disputed' : 'Pending'}
        </span>
      </div>

      <div className="row" style={{ gap: 'var(--s-2)', marginBottom: 'var(--s-3)' }}>
        <input className="input num" inputMode="numeric" aria-label={`${teamA?.name} score`} value={String(scoreA)}
          onChange={(e) => setScoreA(Math.min(99, Number(e.target.value.replace(/\D/g, '') || 0)))}
          style={{ textAlign: 'center', fontWeight: 700 }} />
        <span className="dim">–</span>
        <input className="input num" inputMode="numeric" aria-label={`${teamB?.name} score`} value={String(scoreB)}
          onChange={(e) => setScoreB(Math.min(99, Number(e.target.value.replace(/\D/g, '') || 0)))}
          style={{ textAlign: 'center', fontWeight: 700 }} />
      </div>

      {shootout && (
        <div className="field" style={{ marginBottom: 'var(--s-3)' }}>
          <span className="field__label">Level — who won on penalties?</span>
          <div className="row" style={{ gap: 'var(--s-2)' }}>
            {[teamA, teamB].map((team) => team && (
              <button key={team.id} type="button" style={{ flex: 1 }}
                className={`btn btn--sm ${pens === team.id ? 'btn--primary' : 'btn--ghost'}`}
                onClick={() => { haptic(); setPens(team.id) }}>
                {team.name}
              </button>
            ))}
          </div>
        </div>
      )}

      <div className="row" style={{ gap: 'var(--s-2)' }}>
        <button className="btn btn--primary btn--sm" disabled={busy || (shootout && !pens)} style={{ flex: 1 }}
          onClick={() => act(
            () => adminResolveMatch(match.id, scoreA, scoreB, 'Settled by admin', shootout ? pens : null),
            'Result settled.',
          )}>
          Settle at {scoreA}–{scoreB}
        </button>
        <ConfirmButton className="btn btn--danger btn--sm" disabled={busy}
          label="Void" confirmLabel="Void it?"
          onConfirm={() => act(() => adminVoidMatch(match.id, 'Voided by admin'), 'Match voided.')} />
      </div>
    </div>
  )
}

// ── Season state ──────────────────────────────────────────────────────────

function SeasonState({ run }: { run: Run }) {
  const league = useLeague()
  const [busy, setBusy] = useState(false)
  const started = league.seasonStarted
  const locked = league.matches.some((m) => m.status === 'confirmed')
    || (league.settings?.phase ?? 'league') !== 'league'

  const set = async (next: boolean) => {
    setBusy(true)
    await run(() => adminSetSeasonStarted(next),
      next ? 'Season started — fixtures generated.' : 'Back to pre-season.')
    setBusy(false)
  }

  return (
    <section className="section">
      <div className="eyebrow">Season state</div>
      <div className="card stack">
        <div className="spread">
          <div style={{ minWidth: 0 }}>
            <div className="t-headline">{started ? 'Season is running' : 'Pre-season'}</div>
            <div className="t-caption dim">
              {started
                ? 'Players can no longer leave their own teams.'
                : 'Either teammate can still walk away and dissolve their team.'}
            </div>
          </div>
          <span className={`pill${started ? ' pill--accent' : ''}`} style={{ flexShrink: 0 }}>
            {started ? 'Started' : 'Open'}
          </span>
        </div>

        {locked ? (
          <p className="field__hint" style={{ padding: 0 }}>
            Results have already been confirmed, so the schedule is fixed and the
            season cannot be reopened. Use Admin → Teams to change a team, or void
            a result to put its fixture back on the schedule.
          </p>
        ) : started ? (
          <>
            <div className="row" style={{ gap: 'var(--s-2)' }}>
              <ConfirmButton
                className="btn btn--ghost btn--sm" style={{ flex: 1 }} disabled={busy}
                label="Reshuffle fixtures" confirmLabel="Rebuild the whole schedule?"
                onConfirm={async () => {
                  setBusy(true)
                  await run(async () => {
                    const made = await adminRegenerateSchedule()
                    return made
                  }, 'Schedule rebuilt.')
                  setBusy(false)
                }}
              />
              <ConfirmButton
                className="btn btn--danger btn--sm" style={{ flex: 1 }} disabled={busy}
                label="Reopen pre-season" confirmLabel="This deletes the schedule — sure?"
                onConfirm={() => set(false)}
              />
            </div>
            <p className="field__hint" style={{ padding: 0 }}>
              {league.schedule.length} fixtures generated. Both options are only
              available while no result has been confirmed.
            </p>
          </>
        ) : (
          <>
            <ConfirmButton
              className="btn btn--primary btn--block"
              disabled={busy}
              label="Start the season"
              confirmLabel="Confirm — generates the fixtures and locks the teams"
              onConfirm={() => set(true)}
            />
            <p className="field__hint" style={{ padding: 0 }}>
              {league.activeTeams.length < 2
                ? 'You need at least two teams to build a schedule.'
                : `${describeSeason(league.activeTeams.length, league.settings?.games_per_team ?? 0)} ` +
                  'It also stops players leaving their teams.'}
            </p>
          </>
        )}
      </div>
    </section>
  )
}

// ── Season ────────────────────────────────────────────────────────────────

function SeasonSettings({ run }: { run: Run }) {
  const { settings, activeTeams, schedule, matches } = useLeague()
  const [name, setName] = useState('')
  const [games, setGames] = useState('12')
  const [buyIn, setBuyIn] = useState('50')
  const [adminEmail, setAdminEmail] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!settings) return
    setName(settings.season_name)
    setGames(String(settings.games_per_team))
    setBuyIn(String(settings.buy_in_cents / 100))
    setAdminEmail(settings.admin_email ?? '')
  }, [settings])

  // A schedule built at the old length would otherwise sit there disagreeing
  // with the setting. While nothing has been played it can simply be rebuilt;
  // after that the fixtures are fixed, so the new length cannot take effect.
  const lengthChanged = Number(games) !== settings?.games_per_team
  const played = matches.some((m) => m.status === 'confirmed')
  const rebuild = lengthChanged && schedule.length > 0 && !played && settings?.phase === 'league'

  const save = async () => {
    setBusy(true)
    await run(
      async () => {
        await adminUpdateSettings(
          name, Number(games) || 0, Math.round((Number(buyIn) || 0) * 100),
          settings?.playoff_size ?? null, adminEmail.trim() || null,
        )
        if (rebuild) await adminRegenerateSchedule()
      },
      rebuild ? 'Season updated — schedule rebuilt.' : 'Season updated.',
    )
    setBusy(false)
  }

  return (
    <section className="section">
      <div className="eyebrow">Season</div>
      <div className="card stack">
        <div className="field">
          <label className="field__label" htmlFor="season-name">Season name</label>
          <input id="season-name" className="input" value={name} onChange={(e) => setName(e.target.value)} />
        </div>
        <div className="row" style={{ gap: 'var(--s-3)', alignItems: 'flex-end' }}>
          <div className="field" style={{ flex: 1 }}>
            <label className="field__label" htmlFor="games">Games per team</label>
            <input id="games" className="input" inputMode="numeric" value={games}
              onChange={(e) => setGames(e.target.value.replace(/\D/g, '').slice(0, 3))} />
          </div>
          <div className="field" style={{ flex: 1 }}>
            <label className="field__label" htmlFor="buyin">Buy-in ($)</label>
            <input id="buyin" className="input" inputMode="numeric" value={buyIn}
              onChange={(e) => setBuyIn(e.target.value.replace(/[^\d.]/g, '').slice(0, 6))} />
          </div>
        </div>
        <p className={`field__hint${Number(games) % 2 ? ' field__hint--bad' : ''}`} style={{ padding: 0 }}>
          {Number(games) % 2
            ? 'Has to be even — you play each opponent twice.'
            : `${describeSeason(
                activeTeams.length, Number(games) || 0,
                // The built schedule only describes the saved setting.
                schedule.length && Number(games) === settings?.games_per_team
                  ? new Set(schedule.map((m) => m.round)).size
                  : undefined,
              )} ${
                schedule.length === 0
                  ? 'Used when the season starts.'
                  : played
                    ? lengthChanged
                      ? "Results are already in, so the schedule can't be rebuilt — saving won't change it."
                      : ''
                    : lengthChanged
                      ? 'Saving rebuilds the schedule.'
                      : ''
              }`}
        </p>
        <div className="field">
          <label className="field__label" htmlFor="admin-email">Admin account (email)</label>
          <input id="admin-email" className="input" type="email" autoCapitalize="none"
            value={adminEmail} onChange={(e) => setAdminEmail(e.target.value)} />
          <p className="field__hint">
            Whoever signs in with this address gets these controls. Changing it hands them over.
          </p>
        </div>
        <button className="btn btn--ghost btn--block" disabled={busy} onClick={save}>
          {busy ? 'Saving…' : 'Save season settings'}
        </button>
      </div>
    </section>
  )
}

// ── Playoffs ──────────────────────────────────────────────────────────────

function Playoffs({ run }: { run: Run }) {
  const league = useLeague()
  const { settings, activeTeams, matches } = league
  const [busy, setBusy] = useState(false)

  const started = settings?.phase !== 'league'
  const unsettled = matches.filter((m) => m.phase === 'league' && (m.status === 'pending' || m.status === 'disputed')).length
  const n = activeTeams.length
  // Mirrors admin_start_playoffs(): the bracket rounds up to a power of two and
  // the spare places are byes for the top seeds.
  let bracket = 1
  while (bracket < n) bracket *= 2
  const byes = bracket - n
  const tooFew = n < 2

  return (
    <section className="section">
      <div className="eyebrow">Playoffs</div>
      <div className="card stack">
        {started ? (
          <>
            <p className="muted t-foot" style={{ margin: 0 }}>
              {settings?.phase === 'complete'
                ? 'The season is finished — a champion has been crowned.'
                : 'The bracket is live and the league table is locked.'}
            </p>
            <ConfirmButton className="btn btn--danger btn--block"
              label="Tear down the bracket" confirmLabel="Delete the bracket and reopen the league?"
              disabled={busy}
              onConfirm={() => { void run(() => adminResetPlayoffs(), 'Back to the league phase.') }} />
          </>
        ) : (
          <>
            <p className="muted t-foot" style={{ margin: 0 }}>
              All {n} teams make the playoffs, seeded by the final table.{' '}
              {byes === 0
                ? 'No byes needed.'
                : byes === 1
                  ? 'The #1 seed gets a first-round bye.'
                  : `The top ${byes} seeds get first-round byes.`}{' '}
              Ties are two legs on aggregate; the final is one game. Starting the
              playoffs locks the league.
              {unsettled > 0 && (
                <> <span style={{ color: 'var(--accent)' }}>
                  {unsettled} unconfirmed {unsettled === 1 ? 'result' : 'results'} will be voided.
                </span></>
              )}
            </p>
            {tooFew && (
              <p className="t-foot" style={{ margin: 0, color: 'var(--danger)' }} role="alert">
                You need at least two active teams.
              </p>
            )}
            <ConfirmButton className="btn btn--primary btn--block"
              label="Start the playoffs" confirmLabel="Confirm — lock the league"
              disabled={busy || tooFew}
              onConfirm={async () => { setBusy(true); await run(() => adminStartPlayoffs(), 'The bracket is live.'); setBusy(false) }} />
          </>
        )}
      </div>
    </section>
  )
}

// ── Teams ─────────────────────────────────────────────────────────────────

function TeamsAdmin({ run }: { run: Run }) {
  const league = useLeague()
  const [pairing, setPairing] = useState(false)
  const [name, setName] = useState('')
  const [a, setA] = useState('')
  const [b, setB] = useState('')
  const [busy, setBusy] = useState(false)

  const create = async () => {
    setBusy(true)
    const ok = await run(() => adminCreateTeam(name, a, b), `${name.trim()} created.`)
    setBusy(false)
    if (ok) { setName(''); setA(''); setB(''); setPairing(false) }
  }

  return (
    <section className="section">
      <div className="spread" style={{ marginBottom: 'var(--s-3)' }}>
        <div className="eyebrow" style={{ margin: '0 0 0 2px' }}>Teams</div>
        <button className="btn btn--quiet btn--sm" style={{ padding: 0 }} onClick={() => setPairing((v) => !v)}>
          {pairing ? 'Cancel' : '+ Pair two players'}
        </button>
      </div>

      <div className="stack">
        {pairing && (
          <div className="card card--accent stack">
            <p className="field__hint" style={{ padding: 0 }}>
              Players normally pair up themselves on the Teams page. Use this when they can't.
            </p>
            <div className="field">
              <label className="field__label" htmlFor="pair-name">Team name</label>
              <input id="pair-name" className="input" value={name} onChange={(e) => setName(e.target.value)} />
            </div>
            <div className="row" style={{ gap: 'var(--s-3)' }}>
              <div className="field" style={{ flex: 1 }}>
                <label className="field__label" htmlFor="pair-a">Player 1</label>
                <select id="pair-a" className="input" value={a} onChange={(e) => setA(e.target.value)}>
                  <option value="">Choose…</option>
                  {league.pool.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                </select>
              </div>
              <div className="field" style={{ flex: 1 }}>
                <label className="field__label" htmlFor="pair-b">Player 2</label>
                <select id="pair-b" className="input" value={b} onChange={(e) => setB(e.target.value)}>
                  <option value="">Choose…</option>
                  {league.pool.filter((p) => p.id !== a).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                </select>
              </div>
            </div>
            <button className="btn btn--primary btn--block"
              disabled={busy || !name.trim() || !a || !b || a === b} onClick={create}>
              {busy ? 'Creating…' : 'Create team'}
            </button>
          </div>
        )}
        {league.teams.length === 0 && !pairing && (
          <div className="card center muted t-subhead" style={{ padding: 'var(--s-6) var(--s-4)' }}>No teams yet.</div>
        )}
        {league.teams.map((team) => <TeamRow key={team.id} team={team} run={run} />)}
      </div>
    </section>
  )
}

function TeamRow({ team, run }: { team: Team; run: Run }) {
  const league = useLeague()
  const roster = league.playersFor(team.id)
  const [open, setOpen] = useState(false)
  const [name, setName] = useState(team.name)
  const [active, setActive] = useState(team.is_active)
  const [paid, setPaid] = useState(team.paid)
  const [busy, setBusy] = useState(false)

  useEffect(() => { setName(team.name); setActive(team.is_active); setPaid(team.paid) }, [team])

  const act = async (work: () => Promise<unknown>, message: string) => {
    setBusy(true); await run(work, message); setBusy(false)
  }

  return (
    <div className="card" style={{ padding: open ? 18 : '14px 16px' }}>
      <button className="spread" onClick={() => setOpen((v) => !v)} style={{ width: '100%', textAlign: 'left', minHeight: 34 }}>
        <span style={{ minWidth: 0 }}>
          <span className="t-headline" style={{ display: 'block' }}>
            {team.name}
            {!team.is_active && (
              <span className="pill" style={{ marginLeft: 'var(--s-2)', height: '1.25rem' }}>Inactive</span>
            )}
          </span>
          <span className="t-caption dim" style={{ display: 'block' }}>
            {roster.join(' & ') || 'No players'} · {team.paid ? 'paid' : 'unpaid'}
          </span>
        </span>
        <span className="dim t-foot" style={{ flexShrink: 0 }}>{open ? 'Close' : 'Edit'}</span>
      </button>

      {open && (
        <div className="stack" style={{ marginTop: 'var(--s-4)' }}>
          <div className="field">
            <label className="field__label" htmlFor={`tn-${team.id}`}>Team name</label>
            <input id={`tn-${team.id}`} className="input" value={name} onChange={(e) => setName(e.target.value)} />
          </div>
          <div className="row" style={{ gap: 'var(--s-2)' }}>
            <Toggle label="In the league" on={active} onClick={() => setActive((v) => !v)} />
            <Toggle label="Buy-in paid" on={paid} onClick={() => setPaid((v) => !v)} />
          </div>
          <button className="btn btn--primary btn--block" disabled={busy}
            onClick={() => act(() => adminUpdateTeam(team.id, name, active, paid), 'Team updated.')}>
            Save changes
          </button>
          <div className="divider" />
          <ConfirmButton className="btn btn--danger btn--block"
            disabled={busy || league.settings?.phase !== 'league'}
            label="Dissolve team" confirmLabel="Break them up and delete their results?"
            onConfirm={() => act(() => adminDissolveTeam(team.id), `${team.name} dissolved.`)} />
          <p className="field__hint" style={{ padding: 0 }}>
            Both players go back to the player pool. Their matches are deleted, so this is league-phase only.
          </p>
        </div>
      )}
    </div>
  )
}

// ── Players ───────────────────────────────────────────────────────────────

function PlayersAdmin({ run }: { run: Run }) {
  const league = useLeague()

  return (
    <section className="section">
      <div className="eyebrow">Players</div>
      <div className="stack">
        <p className="field__hint" style={{ padding: 0 }}>
          Players only exist by signing themselves up — there is no way to add one
          from here.
        </p>
        {league.players.map((p) => <PlayerRow key={p.id} player={p} run={run} />)}
      </div>
    </section>
  )
}

function PlayerRow({ player, run }: { player: Player; run: Run }) {
  const league = useLeague()
  const [open, setOpen] = useState(false)
  const [name, setName] = useState(player.name)
  const [busy, setBusy] = useState(false)

  useEffect(() => { setName(player.name) }, [player])

  const act = async (work: () => Promise<unknown>, message: string) => {
    setBusy(true); await run(work, message); setBusy(false)
  }
  const team = league.teamById(player.team_id)

  return (
    <div className="card" style={{ padding: open ? 18 : '13px 16px' }}>
      <button className="spread" onClick={() => setOpen((v) => !v)} style={{ width: '100%', textAlign: 'left', minHeight: 32 }}>
        <span style={{ minWidth: 0 }}>
          <span className="t-headline" style={{ display: 'block' }}>
            {player.name}
            {player.is_admin && (
              <span className="pill pill--accent" style={{ marginLeft: 'var(--s-2)', height: '1.25rem' }}>Admin</span>
            )}
          </span>
          <span className="t-caption dim" style={{ display: 'block' }}>
            {team ? team.name : 'No team'}
            {player.email ? ` · ${player.email}` : ' · not signed up yet'}
          </span>
        </span>
        <span className="dim t-foot" style={{ flexShrink: 0 }}>{open ? 'Close' : 'Edit'}</span>
      </button>

      {open && (
        <div className="stack" style={{ marginTop: 'var(--s-4)' }}>
          <div className="field">
            <label className="field__label" htmlFor={`pn-${player.id}`}>Name</label>
            <div className="row" style={{ gap: 'var(--s-2)' }}>
              <input id={`pn-${player.id}`} className="input" value={name} onChange={(e) => setName(e.target.value)} />
              <button className="btn btn--ghost" disabled={busy || name.trim() === player.name}
                onClick={() => act(() => adminRenamePlayer(player.id, name), 'Name updated.')}>
                Save
              </button>
            </div>
          </div>

          <ConfirmButton className="btn btn--danger btn--block"
            disabled={busy || player.team_id !== null}
            label="Delete" confirmLabel="Delete for good?"
            onConfirm={() => act(() => adminDeletePlayer(player.id), `${player.name} removed.`)} />
          {player.team_id !== null && (
            <p className="field__hint" style={{ padding: 0 }}>
              Dissolve their team before deleting them.
            </p>
          )}
        </div>
      )}
    </div>
  )
}

// ── Chat moderation ───────────────────────────────────────────────────────

function ChatModeration({ run }: { run: Run }) {
  const league = useLeague()
  const recent = [...league.messages].reverse().slice(0, 25)

  return (
    <section className="section">
      <div className="eyebrow">Chat</div>
      {recent.length === 0 ? (
        <div className="card center muted t-subhead" style={{ padding: 'var(--s-6) var(--s-4)' }}>No messages yet.</div>
      ) : (
        <div className="card card--flat">
          {recent.map((message, index) => (
            <div key={message.id} className="spread"
              style={{ padding: 'var(--s-3) var(--s-4)', borderTop: index === 0 ? 'none' : '1px solid var(--sep)', gap: 'var(--s-3)' }}>
              <div style={{ minWidth: 0 }}>
                <div className="t-caption dim">
                  {message.kind === 'result' ? 'Result' : message.kind === 'taunt' ? 'Taunt' : message.author_name}
                  {message.team_name && ` · ${message.team_name}`} · {timeAgo(message.created_at)}
                </div>
                <div className="t-subhead" style={{ overflowWrap: 'anywhere' }}>{message.body}</div>
              </div>
              <ConfirmButton className="btn btn--quiet btn--sm" style={{ flexShrink: 0, color: 'var(--danger)' }}
                label="Delete" confirmLabel="Sure?"
                onConfirm={() => { void run(() => adminDeleteMessage(message.id), 'Message deleted.') }} />
            </div>
          ))}
        </div>
      )}
    </section>
  )
}

function Toggle({ label, on, onClick }: { label: string; on: boolean; onClick: () => void }) {
  return (
    <button type="button" onClick={() => { haptic(); onClick() }}
      className={`btn btn--sm ${on ? 'btn--primary' : 'btn--ghost'}`} style={{ flex: 1, minHeight: 44 }}>
      {label}
    </button>
  )
}
