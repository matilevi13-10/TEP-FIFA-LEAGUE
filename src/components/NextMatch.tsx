import { useMemo, useState } from 'react'
import { bySchedule, fixtureLabel, tieLegs, useLeague } from '../lib/league'
import { cancelSubmission } from '../lib/actions'
import { useToast } from './Toast'
import { haptic, timeAgo } from '../lib/format'
import { readableError } from '../lib/supabase'
import { ScoreSheet } from './ScoreSheet'
import type { Match } from '../lib/types'

/**
 * The fixture in front of you. It moves through three states — play it, wait
 * for the other side, then on to the next one — so the card always says what
 * happens next rather than making you go looking.
 */
export function NextMatch() {
  const league = useLeague()
  const toast = useToast()
  const [busy, setBusy] = useState(false)
  const [entering, setEntering] = useState(false)

  const { myTeam, nextFixture, awaitingConfirmation, myFixtures, seasonStarted, settings } = league
  const inPlayoffs = settings?.phase === 'playoffs' || settings?.phase === 'complete'

  // In the playoffs the bracket supplies the fixture instead of the schedule.
  // A second leg only comes up once the first is confirmed.
  const playoffFixture = useMemo(() => {
    if (!myTeam || !inPlayoffs) return undefined
    return [...league.matches].sort(bySchedule).find(
      (m) =>
        m.phase === 'playoff' &&
        (m.status === 'scheduled' || m.status === 'disputed') &&
        m.team_a !== null && m.team_b !== null &&
        (m.team_a === myTeam.id || m.team_b === myTeam.id) &&
        (m.leg === 1 || tieLegs(league.matches, m.round, m.slot)[0]?.status === 'confirmed'),
    )
  }, [myTeam, league.matches, inPlayoffs])

  if (!myTeam) return null
  const fixture = inPlayoffs ? playoffFixture : nextFixture

  const lastResult = [...myFixtures]
    .filter((m) => m.status === 'confirmed')
    .sort((a, b) => (b.confirmed_at ?? '').localeCompare(a.confirmed_at ?? ''))[0]

  // Waiting on the opponent to confirm what we sent.
  if (awaitingConfirmation) {
    const mineFirst = awaitingConfirmation.team_a === myTeam.id
    const other = league.teamById(mineFirst ? awaitingConfirmation.team_b : awaitingConfirmation.team_a)
    const my = (mineFirst ? awaitingConfirmation.score_a : awaitingConfirmation.score_b) ?? 0
    const their = (mineFirst ? awaitingConfirmation.score_b : awaitingConfirmation.score_a) ?? 0

    return (
      <section className="section">
        <div className="eyebrow">Next match</div>
        <div className="card">
          <div className="spread" style={{ marginBottom: 'var(--s-3)' }}>
            <div style={{ minWidth: 0 }}>
              <div className="t-headline row" style={{ gap: 'var(--s-2)' }}>
                <span className="pill pill--live" style={{ height: '1.375rem' }}>Waiting</span>
                <span className="truncate">for {other?.name ?? 'them'} to confirm</span>
              </div>
              <div className="t-caption dim">Sent {timeAgo(awaitingConfirmation.updated_at)}</div>
            </div>
            <div className="num t-title-2" style={{ flexShrink: 0 }}>{my}–{their}</div>
          </div>
          <button
            className="btn btn--ghost btn--block btn--sm"
            disabled={busy}
            onClick={async () => {
              setBusy(true)
              try {
                await cancelSubmission(awaitingConfirmation.id)
                haptic()
                toast('Submission taken back.', 'good')
                await league.refresh()
              } catch (cause) { toast(readableError(cause), 'bad') } finally { setBusy(false) }
            }}
          >
            Undo — I typed it wrong
          </button>
        </div>
      </section>
    )
  }

  if (!seasonStarted && !inPlayoffs) {
    return (
      <section className="section">
        <div className="eyebrow">Next match</div>
        <div className="card center" style={{ padding: 'var(--s-6) var(--s-4)' }}>
          <p className="muted t-subhead" style={{ margin: 0 }}>
            Fixtures appear when the admin starts the season.
          </p>
        </div>
      </section>
    )
  }

  if (!fixture) {
    return (
      <section className="section">
        <div className="eyebrow">{inPlayoffs ? 'Playoffs' : 'Season complete'}</div>
        <div className="card center" style={{ padding: 'var(--s-6) var(--s-4)' }}>
          <p className="muted t-subhead" style={{ margin: 0 }}>
            {inPlayoffs
              ? settings?.phase === 'complete'
                ? 'The season is finished.'
                : 'No open playoff game — either you are out, or your next opponent is still being decided.'
              : "You've played every fixture. Waiting on the playoffs."}
          </p>
        </div>
        {lastResult && <LastResult match={lastResult} teamId={myTeam.id} />}
      </section>
    )
  }

  const mineFirst = fixture.team_a === myTeam.id
  const opponent = league.teamById(mineFirst ? fixture.team_b : fixture.team_a)
  const roster = opponent ? league.playersFor(opponent.id) : []
  const atHome = fixture.home_team === myTeam.id

  return (
    <section className="section">
      <div className="eyebrow eyebrow--accent">Next match</div>
      <div className="card card--accent">
        <div className="spread" style={{ marginBottom: 'var(--s-4)' }}>
          <div style={{ minWidth: 0 }}>
            <div className="t-title-2 truncate">{opponent?.name ?? 'TBC'}</div>
            <div className="t-caption dim">{roster.join(' & ')}</div>
          </div>
          <span className="pill" style={{ flexShrink: 0 }}>
            {fixtureLabel(fixture, league.matches)}
          </span>
        </div>

        {fixture.home_team && (
          <p className="t-foot muted" style={{ margin: '0 0 var(--s-4)' }}>
            {atHome
              ? "You're home — you pick your team and the console."
              : `Away — ${opponent?.name ?? 'they'} pick their team and the console.`}
          </p>
        )}

        {fixture.status === 'disputed' && (
          <p className="field__hint field__hint--bad" style={{ padding: 0, marginBottom: 'var(--s-3)' }}>
            The last score for this fixture was disputed. Enter it again, or let the admin settle it.
          </p>
        )}

        <button className="btn btn--primary btn--block" onClick={() => { haptic(); setEntering(true) }}>
          Submit Score
        </button>
      </div>
      {lastResult && <LastResult match={lastResult} teamId={myTeam.id} />}

      {entering && (
        <ScoreSheet fixture={fixture} myTeam={myTeam} onClose={() => setEntering(false)} />
      )}
    </section>
  )
}

function LastResult({ match, teamId }: { match: Match; teamId: string }) {
  const league = useLeague()
  const mineFirst = match.team_a === teamId
  const my = (mineFirst ? match.score_a : match.score_b) ?? 0
  const their = (mineFirst ? match.score_b : match.score_a) ?? 0
  const other = league.teamById(mineFirst ? match.team_b : match.team_a)
  const won = my > their

  return (
    <div className="spread t-foot" style={{ padding: 'var(--s-3) var(--s-1) 0' }}>
      <span className="dim">
        Last time out · {won ? 'beat' : my === their ? 'drew with' : 'lost to'} {other?.name ?? 'them'}
      </span>
      <span className="num" style={{ fontWeight: 600, color: won ? 'var(--accent)' : 'var(--text-3)' }}>
        {my}–{their}
      </span>
    </div>
  )
}
