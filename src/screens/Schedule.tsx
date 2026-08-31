import { useState } from 'react'
import { useAuth } from '../lib/auth'
import { useLeague } from '../lib/league'
import type { Match } from '../lib/types'

/** The season's fixtures — yours, and the whole league by round. */
export function Schedule() {
  const { player } = useAuth()
  const league = useLeague()
  const [view, setView] = useState<'mine' | 'all'>(player?.team_id ? 'mine' : 'all')

  const { schedule, myFixtures, myTeam } = league
  if (!player) return null

  const rounds = [...new Set(schedule.map((m) => m.round ?? 0))].sort((a, b) => a - b)

  return (
    <div className="page">
      <div className="section" style={{ marginBottom: 'var(--s-5)' }}>
        <h1 className="t-title" style={{ margin: 0 }}>Schedule</h1>
        <div className="t-foot dim">
          {schedule.length === 0
            ? 'No fixtures yet — the admin starts the season.'
            : `${schedule.length} fixtures across ${rounds.length} rounds`}
        </div>
      </div>

      {schedule.length === 0 ? (
        <div className="card center muted t-subhead" style={{ padding: 'var(--s-8) var(--s-4)' }}>
          The season hasn't started.
        </div>
      ) : (
        <>
          {myTeam && (
            <div className="row" style={{ gap: 'var(--s-2)', marginBottom: 'var(--s-4)' }}>
              <button className={`btn btn--sm ${view === 'mine' ? 'btn--primary' : 'btn--ghost'}`}
                style={{ flex: 1 }} onClick={() => setView('mine')}>
                My fixtures
              </button>
              <button className={`btn btn--sm ${view === 'all' ? 'btn--primary' : 'btn--ghost'}`}
                style={{ flex: 1 }} onClick={() => setView('all')}>
                Full league
              </button>
            </div>
          )}

          {view === 'mine' && myTeam ? (
            <section className="section" style={{ marginTop: 0 }}>
              <div className="card card--flat">
                {myFixtures.map((m, i) => (
                  <Fixture key={m.id} match={m} highlight={myTeam.id} first={i === 0} />
                ))}
              </div>
            </section>
          ) : (
            rounds.map((round) => (
              <section className="section" key={round} style={{ marginTop: 'var(--s-5)' }}>
                <div className="eyebrow">Round {round}</div>
                <div className="card card--flat">
                  {schedule
                    .filter((m) => (m.round ?? 0) === round)
                    .map((m, i) => (
                      <Fixture key={m.id} match={m} highlight={myTeam?.id} first={i === 0}
                        showRound={false} />
                    ))}
                </div>
              </section>
            ))
          )}
        </>
      )}
    </div>
  )
}

function Fixture({ match, highlight, first, showRound = true }:
  { match: Match; highlight?: string; first: boolean; showRound?: boolean }) {
  const league = useLeague()
  const a = league.teamById(match.team_a)
  const b = league.teamById(match.team_b)
  const played = match.status === 'confirmed'
  const mine = highlight && (match.team_a === highlight || match.team_b === highlight)

  const label =
    match.status === 'pending' ? 'Awaiting confirmation'
      : match.status === 'disputed' ? 'Disputed'
      : match.status === 'voided' ? 'Voided'
      : played ? null
      : showRound ? `Round ${match.round}` : null

  return (
    <div
      className="spread"
      style={{
        padding: 'var(--s-3) var(--s-4)',
        borderTop: first ? 'none' : '1px solid var(--sep)',
        background: mine ? 'var(--accent-fill)' : undefined,
      }}
    >
      <div style={{ minWidth: 0 }}>
        <div className="t-subhead truncate">
          <span style={{ fontWeight: played && match.winner_id === match.team_a ? 700 : 400 }}>
            {a?.name ?? 'TBC'}
          </span>
          <span className="dim"> v </span>
          <span style={{ fontWeight: played && match.winner_id === match.team_b ? 700 : 400 }}>
            {b?.name ?? 'TBC'}
          </span>
        </div>
        {label && <div className="t-caption dim">{label}</div>}
      </div>
      <div className="num t-headline" style={{ flexShrink: 0, color: played ? 'var(--text)' : 'var(--text-3)' }}>
        {played ? `${match.score_a}–${match.score_b}` : '–'}
      </div>
    </div>
  )
}
