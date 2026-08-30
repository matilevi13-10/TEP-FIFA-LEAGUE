import { useEffect, useState } from 'react'
import { useAuth } from '../lib/auth'
import { useLeague } from '../lib/league'
import {
  adminCreateTeam, adminDeleteTeam, adminResetPlayoffs, adminResolveMatch, adminSetPin,
  adminSetRole, adminStartPlayoffs, adminUpdateSettings, adminUpdateTeam, adminVoidMatch,
} from '../lib/actions'
import { ConfirmButton } from '../components/ConfirmButton'
import { useToast } from '../components/Toast'
import { readableError } from '../lib/supabase'
import { haptic, money, timeAgo } from '../lib/format'
import type { Match, Team } from '../lib/types'

export function Admin() {
  const { team } = useAuth()
  const league = useLeague()
  const toast = useToast()

  if (!team?.is_admin) {
    return (
      <div className="page">
        <div className="section card center muted" style={{ padding: 30 }}>Admins only.</div>
      </div>
    )
  }

  const run = async (work: () => Promise<unknown>, message: string) => {
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
      <div className="section" style={{ marginBottom: 18 }}>
        <h1 style={{ fontSize: 26, fontWeight: 500, letterSpacing: '-0.02em', margin: 0 }}>Admin</h1>
        <div style={{ fontSize: 13, color: 'var(--text-3)' }}>
          {league.settings?.season_name} · {league.activeTeams.length} teams · pot {money(league.potCents)}
        </div>
      </div>

      <NeedsAttention run={run} />
      <SeasonSettings run={run} />
      <Playoffs run={run} />
      <Teams run={run} />
    </div>
  )
}

type Run = (work: () => Promise<unknown>, message: string) => Promise<boolean>

// ── Disputes and pending results ──────────────────────────────────────────

function NeedsAttention({ run }: { run: Run }) {
  const league = useLeague()
  const flagged = league.matches.filter((m) => m.status === 'disputed')
  const waiting = league.matches.filter((m) => m.status === 'pending')

  if (flagged.length === 0 && waiting.length === 0) return null

  return (
    <section className="section">
      <div className="eyebrow" style={{ color: flagged.length ? 'var(--accent)' : undefined }}>
        {flagged.length > 0
          ? `${flagged.length} disputed`
          : `${waiting.length} awaiting confirmation`}
      </div>
      <div className="stack">
        {[...flagged, ...waiting].map((match) => (
          <MatchRow key={match.id} match={match} run={run} />
        ))}
      </div>
    </section>
  )
}

function MatchRow({ match, run }: { match: Match; run: Run }) {
  const league = useLeague()
  const [scoreA, setScoreA] = useState(match.score_a ?? 0)
  const [scoreB, setScoreB] = useState(match.score_b ?? 0)
  const [busy, setBusy] = useState(false)

  const teamA = league.teamById(match.team_a)
  const teamB = league.teamById(match.team_b)
  const submitter = league.teamById(match.submitted_by)

  const act = async (work: () => Promise<unknown>, message: string) => {
    setBusy(true)
    await run(work, message)
    setBusy(false)
  }

  return (
    <div className="card">
      <div className="spread" style={{ marginBottom: 12 }}>
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 15, fontWeight: 500 }}>
            {teamA?.name ?? '—'} vs {teamB?.name ?? '—'}
          </div>
          <div style={{ fontSize: 12, color: 'var(--text-3)' }}>
            {match.phase === 'playoff' ? 'Playoff' : 'League'} · sent by {submitter?.name ?? 'unknown'} ·{' '}
            {timeAgo(match.created_at)}
          </div>
        </div>
        <span className={`pill${match.status === 'disputed' ? ' pill--accent' : ''}`}>
          {match.status === 'disputed' ? 'Disputed' : 'Pending'}
        </span>
      </div>

      <div className="row" style={{ gap: 8, marginBottom: 12 }}>
        <input
          className="input" inputMode="numeric" aria-label={`${teamA?.name} score`}
          value={String(scoreA)}
          onChange={(e) => setScoreA(Math.min(99, Number(e.target.value.replace(/\D/g, '') || 0)))}
          style={{ textAlign: 'center', fontWeight: 700, fontSize: 18 }}
        />
        <span className="dim">–</span>
        <input
          className="input" inputMode="numeric" aria-label={`${teamB?.name} score`}
          value={String(scoreB)}
          onChange={(e) => setScoreB(Math.min(99, Number(e.target.value.replace(/\D/g, '') || 0)))}
          style={{ textAlign: 'center', fontWeight: 700, fontSize: 18 }}
        />
      </div>

      <div className="row" style={{ gap: 8 }}>
        <button
          className="btn btn--primary btn--sm" disabled={busy} style={{ flex: 1 }}
          onClick={() => act(() => adminResolveMatch(match.id, scoreA, scoreB, 'Settled by admin'), 'Result settled.')}
        >
          Settle at {scoreA}–{scoreB}
        </button>
        <ConfirmButton
          className="btn btn--danger btn--sm" disabled={busy}
          label="Void" confirmLabel="Void it?"
          onConfirm={() => act(() => adminVoidMatch(match.id, 'Voided by admin'), 'Match voided.')}
        />
      </div>
    </div>
  )
}

// ── Season settings ───────────────────────────────────────────────────────

function SeasonSettings({ run }: { run: Run }) {
  const { settings } = useLeague()
  const [name, setName] = useState('')
  const [games, setGames] = useState('10')
  const [buyIn, setBuyIn] = useState('50')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!settings) return
    setName(settings.season_name)
    setGames(String(settings.games_per_team))
    setBuyIn(String(settings.buy_in_cents / 100))
  }, [settings])

  const save = async () => {
    setBusy(true)
    await run(
      () => adminUpdateSettings(name, Number(games) || 1, Math.round((Number(buyIn) || 0) * 100), settings?.playoff_size ?? null),
      'Season updated.',
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
        <div className="row" style={{ gap: 10, alignItems: 'flex-end' }}>
          <div className="field" style={{ flex: 1 }}>
            <label className="field__label" htmlFor="games">Games per team</label>
            <input id="games" className="input num" inputMode="numeric" value={games}
              onChange={(e) => setGames(e.target.value.replace(/\D/g, '').slice(0, 3))} />
          </div>
          <div className="field" style={{ flex: 1 }}>
            <label className="field__label" htmlFor="buyin">Buy-in ($)</label>
            <input id="buyin" className="input num" inputMode="numeric" value={buyIn}
              onChange={(e) => setBuyIn(e.target.value.replace(/[^\d.]/g, '').slice(0, 6))} />
          </div>
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
  const [size, setSize] = useState<number>(settings?.playoff_size ?? 8)
  const [busy, setBusy] = useState(false)

  useEffect(() => { if (settings?.playoff_size) setSize(settings.playoff_size) }, [settings?.playoff_size])

  const started = settings?.phase !== 'league'
  const unsettled = matches.filter((m) => m.phase === 'league' && (m.status === 'pending' || m.status === 'disputed')).length
  const tooFew = activeTeams.length < size

  const start = async () => {
    setBusy(true)
    await run(() => adminStartPlayoffs(size), `${size}-team bracket is live.`)
    setBusy(false)
  }

  return (
    <section className="section">
      <div className="eyebrow">Playoffs</div>
      <div className="card stack">
        <div className="field">
          <span className="field__label">Teams that qualify</span>
          <div className="row" style={{ gap: 8 }}>
            {[4, 8, 16].map((option) => (
              <button
                key={option}
                className={`btn ${size === option ? 'btn--primary' : 'btn--ghost'}`}
                disabled={started}
                onClick={() => { haptic(); setSize(option) }}
                style={{ flex: 1, minHeight: 48 }}
              >
                {option}
              </button>
            ))}
          </div>
        </div>

        {started ? (
          <>
            <p className="muted" style={{ margin: 0, fontSize: 13 }}>
              {settings?.phase === 'complete'
                ? 'The season is finished — a champion has been crowned.'
                : `The bracket is live and the league table is locked.`}
            </p>
            <ConfirmButton
              className="btn btn--danger btn--block"
              label="Tear down the bracket"
              confirmLabel="Delete the bracket and reopen the league?"
              disabled={busy}
              onConfirm={() => { void run(() => adminResetPlayoffs(), 'Back to the league phase.') }}
            />
          </>
        ) : (
          <>
            <p className="muted" style={{ margin: 0, fontSize: 13 }}>
              Starting the playoffs locks the league — no more league results after that. The top {size} seed
              into the bracket.
              {unsettled > 0 && (
                <>
                  {' '}
                  <span style={{ color: 'var(--accent)' }}>
                    {unsettled} unconfirmed {unsettled === 1 ? 'result' : 'results'} will be voided.
                  </span>
                </>
              )}
            </p>
            {tooFew && (
              <p style={{ margin: 0, fontSize: 13, color: 'var(--danger)' }}>
                Only {activeTeams.length} active teams — you need {size}.
              </p>
            )}
            <ConfirmButton
              className="btn btn--primary btn--block"
              label={`Start the ${size}-team playoffs`}
              confirmLabel="Confirm — lock the league"
              disabled={busy || tooFew}
              onConfirm={start}
            />
          </>
        )}
      </div>
    </section>
  )
}

// ── Teams ─────────────────────────────────────────────────────────────────

function Teams({ run }: { run: Run }) {
  const league = useLeague()
  const [adding, setAdding] = useState(false)

  return (
    <section className="section">
      <div className="spread" style={{ marginBottom: 10 }}>
        <div className="eyebrow" style={{ margin: '0 0 0 2px' }}>Teams</div>
        <button className="btn btn--quiet btn--sm" style={{ padding: 0 }} onClick={() => setAdding((v) => !v)}>
          {adding ? 'Cancel' : '+ Add team'}
        </button>
      </div>

      <div className="stack">
        {adding && <AddTeam run={run} onDone={() => setAdding(false)} />}
        {league.teams.map((team) => <TeamRow key={team.id} team={team} run={run} />)}
      </div>
    </section>
  )
}

function AddTeam({ run, onDone }: { run: Run; onDone: () => void }) {
  const [name, setName] = useState('')
  const [one, setOne] = useState('')
  const [two, setTwo] = useState('')
  const [pin, setPin] = useState('')
  const [busy, setBusy] = useState(false)

  const valid = name.trim() && one.trim() && two.trim() && /^\d{4}$/.test(pin)

  const create = async () => {
    setBusy(true)
    const ok = await run(() => adminCreateTeam(name, one, two, pin), `${name.trim()} is in.`)
    setBusy(false)
    if (ok) { setName(''); setOne(''); setTwo(''); setPin(''); onDone() }
  }

  return (
    <div className="card card--accent stack">
      <div className="field">
        <label className="field__label" htmlFor="new-name">Team name</label>
        <input id="new-name" className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="Los Galácticos" />
      </div>
      <div className="row" style={{ gap: 10 }}>
        <div className="field" style={{ flex: 1 }}>
          <label className="field__label" htmlFor="new-p1">Player 1</label>
          <input id="new-p1" className="input" value={one} onChange={(e) => setOne(e.target.value)} />
        </div>
        <div className="field" style={{ flex: 1 }}>
          <label className="field__label" htmlFor="new-p2">Player 2</label>
          <input id="new-p2" className="input" value={two} onChange={(e) => setTwo(e.target.value)} />
        </div>
      </div>
      <div className="field">
        <label className="field__label" htmlFor="new-pin">4-digit PIN</label>
        <input
          id="new-pin" className="input num" inputMode="numeric" value={pin} placeholder="0000"
          onChange={(e) => setPin(e.target.value.replace(/\D/g, '').slice(0, 4))}
          style={{ letterSpacing: '0.3em' }}
        />
      </div>
      <button className="btn btn--primary btn--block" disabled={!valid || busy} onClick={create}>
        {busy ? 'Creating…' : 'Create team'}
      </button>
    </div>
  )
}

function TeamRow({ team, run }: { team: Team; run: Run }) {
  const league = useLeague()
  const [open, setOpen] = useState(false)
  const [name, setName] = useState(team.name)
  const [one, setOne] = useState(team.player_one)
  const [two, setTwo] = useState(team.player_two)
  const [active, setActive] = useState(team.is_active)
  const [paid, setPaid] = useState(team.paid)
  const [pin, setPin] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    setName(team.name); setOne(team.player_one); setTwo(team.player_two)
    setActive(team.is_active); setPaid(team.paid)
  }, [team])

  const act = async (work: () => Promise<unknown>, message: string) => {
    setBusy(true)
    await run(work, message)
    setBusy(false)
  }

  return (
    <div className="card" style={{ padding: open ? 18 : '14px 16px' }}>
      <button
        className="spread"
        onClick={() => setOpen((v) => !v)}
        style={{ width: '100%', textAlign: 'left', minHeight: 34 }}
      >
        <span style={{ minWidth: 0 }}>
          <span style={{ display: 'block', fontSize: 15, fontWeight: 500 }}>
            {team.name}
            {team.is_admin && <span className="pill pill--accent" style={{ marginLeft: 8, height: 20, fontSize: 10.5 }}>Admin</span>}
            {!team.is_active && <span className="pill" style={{ marginLeft: 8, height: 20, fontSize: 10.5 }}>Inactive</span>}
          </span>
          <span style={{ display: 'block', fontSize: 12, color: 'var(--text-3)' }}>
            {team.player_one} &amp; {team.player_two}
            {team.is_active && ` · ${team.paid ? 'paid' : 'unpaid'}`}
            {!team.user_id && ' · never signed in'}
          </span>
        </span>
        <span className="dim" style={{ fontSize: 13, flexShrink: 0 }}>{open ? 'Close' : 'Edit'}</span>
      </button>

      {open && (
        <div className="stack" style={{ marginTop: 16 }}>
          <div className="field">
            <label className="field__label" htmlFor={`n-${team.id}`}>Team name</label>
            <input id={`n-${team.id}`} className="input" value={name} onChange={(e) => setName(e.target.value)} />
          </div>
          <div className="row" style={{ gap: 10 }}>
            <div className="field" style={{ flex: 1 }}>
              <label className="field__label" htmlFor={`a-${team.id}`}>Player 1</label>
              <input id={`a-${team.id}`} className="input" value={one} onChange={(e) => setOne(e.target.value)} />
            </div>
            <div className="field" style={{ flex: 1 }}>
              <label className="field__label" htmlFor={`b-${team.id}`}>Player 2</label>
              <input id={`b-${team.id}`} className="input" value={two} onChange={(e) => setTwo(e.target.value)} />
            </div>
          </div>

          <div className="row" style={{ gap: 8 }}>
            <Toggle label="In the league" on={active} onClick={() => setActive((v) => !v)} />
            <Toggle label="Buy-in paid" on={paid} onClick={() => setPaid((v) => !v)} />
          </div>

          <button
            className="btn btn--primary btn--block" disabled={busy}
            onClick={() => act(() => adminUpdateTeam(team.id, name, one, two, active, paid), 'Team updated.')}
          >
            Save changes
          </button>

          <div className="divider" />

          <div className="field">
            <label className="field__label" htmlFor={`p-${team.id}`}>Reset PIN</label>
            <div className="row" style={{ gap: 8 }}>
              <input
                id={`p-${team.id}`} className="input num" inputMode="numeric" placeholder="New 4-digit PIN"
                value={pin} onChange={(e) => setPin(e.target.value.replace(/\D/g, '').slice(0, 4))}
                style={{ letterSpacing: '0.2em' }}
              />
              <button
                className="btn btn--ghost" disabled={!/^\d{4}$/.test(pin) || busy}
                onClick={() => act(async () => { await adminSetPin(team.id, pin); setPin('') }, `PIN reset for ${team.name}.`)}
              >
                Set
              </button>
            </div>
          </div>

          <div className="row" style={{ gap: 8 }}>
            <ConfirmButton
              className="btn btn--ghost btn--sm" style={{ flex: 1 }} disabled={busy}
              label={team.is_admin ? 'Remove admin' : 'Make admin'}
              confirmLabel="Sure?"
              onConfirm={() => act(() => adminSetRole(team.id, !team.is_admin), 'Role updated.')}
            />
            <ConfirmButton
              className="btn btn--danger btn--sm" style={{ flex: 1 }}
              disabled={busy || league.settings?.phase !== 'league'}
              label="Delete team" confirmLabel="Delete for good?"
              onConfirm={() => act(() => adminDeleteTeam(team.id), `${team.name} removed.`)}
            />
          </div>
          <p className="dim" style={{ fontSize: 11.5, margin: 0 }}>
            Deleting a team also deletes its results. Only possible during the league phase.
          </p>
        </div>
      )}
    </div>
  )
}

function Toggle({ label, on, onClick }: { label: string; on: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={() => { haptic(); onClick() }}
      className={`btn btn--sm ${on ? 'btn--primary' : 'btn--ghost'}`}
      style={{ flex: 1, minHeight: 44 }}
    >
      {label}
    </button>
  )
}
