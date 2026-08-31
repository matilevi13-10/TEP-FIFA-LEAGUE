import { Link } from 'react-router-dom'
import { useLeague } from '../lib/league'
import { cancelSubmission } from '../lib/actions'
import { useToast } from './Toast'
import { haptic, timeAgo } from '../lib/format'
import { readableError } from '../lib/supabase'
import { useState } from 'react'
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

  const { myTeam, nextFixture, awaitingConfirmation, myFixtures, seasonStarted } = league
  if (!myTeam) return null

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

  if (!seasonStarted) {
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

  if (!nextFixture) {
    return (
      <section className="section">
        <div className="eyebrow">Season complete</div>
        <div className="card center" style={{ padding: 'var(--s-6) var(--s-4)' }}>
          <p className="muted t-subhead" style={{ margin: 0 }}>
            You've played every fixture. Waiting on the playoffs.
          </p>
        </div>
        {lastResult && <LastResult match={lastResult} teamId={myTeam.id} />}
      </section>
    )
  }

  const mineFirst = nextFixture.team_a === myTeam.id
  const opponent = league.teamById(mineFirst ? nextFixture.team_b : nextFixture.team_a)
  const roster = opponent ? league.playersFor(opponent.id) : []

  return (
    <section className="section">
      <div className="eyebrow eyebrow--accent">Next match</div>
      <div className="card card--accent">
        <div className="spread" style={{ marginBottom: 'var(--s-4)' }}>
          <div style={{ minWidth: 0 }}>
            <div className="t-title-2 truncate">{opponent?.name ?? 'TBC'}</div>
            <div className="t-caption dim">{roster.join(' & ')}</div>
          </div>
          <span className="pill" style={{ flexShrink: 0 }}>Round {nextFixture.round}</span>
        </div>

        {nextFixture.status === 'disputed' && (
          <p className="field__hint field__hint--bad" style={{ padding: 0, marginBottom: 'var(--s-3)' }}>
            The last score for this fixture was disputed. Enter it again, or let the admin settle it.
          </p>
        )}

        <Link to="/submit" className="btn btn--primary btn--block">Submit Score</Link>
      </div>
      {lastResult && <LastResult match={lastResult} teamId={myTeam.id} />}
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
        Last time out · {won ? 'beat' : 'lost to'} {other?.name ?? 'them'}
      </span>
      <span className="num" style={{ fontWeight: 600, color: won ? 'var(--accent)' : 'var(--text-3)' }}>
        {my}–{their}
      </span>
    </div>
  )
}
