import { useState } from 'react'
import { useAuth } from '../lib/auth'
import { slotsUsed, useLeague } from '../lib/league'
import { cancelSubmission, confirmMatch, disputeMatch } from '../lib/actions'
import { AddTeamForm } from '../components/AddTeamForm'
import { useToast } from '../components/Toast'
import { IconCheck, IconTrophy } from '../components/Icons'
import { haptic, money, ordinal, timeAgo } from '../lib/format'
import { readableError } from '../lib/supabase'
import type { Match } from '../lib/types'

export function Home() {
  const { player } = useAuth()
  const league = useLeague()
  const toast = useToast()
  const [busyId, setBusyId] = useState<string | null>(null)

  if (!player) return null
  const { settings, standings, matches, pendingForMe, awaitingOthers, potCents, activeTeams, myTeam } = league

  const me = myTeam ? standings.find((row) => row.team_id === myTeam.id) : undefined
  const used = myTeam ? slotsUsed(matches, myTeam.id) : 0
  const total = settings?.games_per_team ?? 0
  const remaining = Math.max(0, total - used)
  const champion = league.teamById(settings?.champion_team_id)
  const qualifying = settings?.playoff_size ?? 0
  const showCutline = settings?.phase === 'league' && qualifying > 0 && standings.length > qualifying

  const act = async (id: string, run: () => Promise<unknown>, message: string) => {
    setBusyId(id)
    try {
      await run()
      haptic([10, 30, 10])
      toast(message, 'good')
      await league.refresh()
    } catch (cause) {
      toast(readableError(cause), 'bad')
    } finally {
      setBusyId(null)
    }
  }

  return (
    <div className="page home">
      <div className="home__col">
        {champion && (
          <div className="card card--accent section" style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <span style={{ width: 30, height: 30, color: 'var(--accent)', flexShrink: 0 }}><IconTrophy /></span>
            <div>
              <div className="eyebrow" style={{ margin: 0 }}>Champions</div>
              <div style={{ fontSize: 20, fontWeight: 500 }}>{champion.name}</div>
              <div style={{ fontSize: 13, color: 'var(--text-2)' }}>Takes the {money(potCents)} pot.</div>
            </div>
          </div>
        )}

        {pendingForMe.length > 0 && (
          <section className="section">
            <div className="eyebrow" style={{ color: 'var(--accent)' }}>
              {pendingForMe.length === 1 ? 'Confirm this result' : `${pendingForMe.length} results to confirm`}
            </div>
            <div className="stack">
              {pendingForMe.map((match) => (
                <PendingCard
                  key={match.id}
                  match={match}
                  busy={busyId === match.id}
                  onConfirm={() => act(match.id, () => confirmMatch(match.id), 'Result confirmed.')}
                  onDispute={() => act(match.id, () => disputeMatch(match.id), 'Flagged for the admin.')}
                />
              ))}
            </div>
          </section>
        )}

        <section className="section">
          <div className="card card--accent" style={{ textAlign: 'center', padding: '26px 18px' }}>
            <div className="eyebrow" style={{ margin: 0 }}>Grand prize</div>
            <div
              style={{
                fontSize: 'clamp(46px, 15vw, 64px)', fontWeight: 700, lineHeight: 1.05,
                letterSpacing: '-0.035em', color: 'var(--accent)',
                textShadow: '0 0 46px rgba(181,168,255,0.42)', margin: '4px 0 6px',
              }}
            >
              {money(potCents)}
            </div>
            <div style={{ fontSize: 13, color: 'var(--text-2)' }}>
              {activeTeams.length} {activeTeams.length === 1 ? 'team' : 'teams'} ×{' '}
              {money(settings?.buy_in_cents ?? 0)} buy-in
            </div>
          </div>
        </section>

        {myTeam ? (
          <section className="section">
            <div className="eyebrow">{myTeam.name}</div>
            <div className="card">
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 10 }}>
                <Stat label="Rank" value={me ? ordinal(me.rank) : '—'} accent />
                <Stat label="Record" value={me ? `${me.won}-${me.drawn}-${me.lost}` : '0-0-0'} />
                <Stat label="Points" value={me ? String(me.points) : '0'} />
              </div>

              <div className="divider" style={{ margin: '16px 0 14px' }} />

              <div className="spread" style={{ fontSize: 13 }}>
                <span className="muted">Games played</span>
                <span style={{ fontWeight: 500 }}>{me?.played ?? 0} <span className="dim">of {total}</span></span>
              </div>
              <div style={{ height: 6, borderRadius: 3, background: 'rgba(255,255,255,0.07)', marginTop: 10, overflow: 'hidden' }}>
                <div
                  style={{
                    height: '100%', width: `${total ? Math.min(100, ((me?.played ?? 0) / total) * 100) : 0}%`,
                    background: 'var(--accent)', boxShadow: '0 0 14px var(--glow)',
                    borderRadius: 3, transition: 'width 420ms var(--ease)',
                  }}
                />
              </div>
              <div className="spread" style={{ fontSize: 12, marginTop: 9, color: 'var(--text-3)' }}>
                <span>
                  {me ? `${me.goals_for}–${me.goals_against} goals` : 'No games yet'}
                  {me && me.goal_difference !== 0 && (
                    <span> ({me.goal_difference > 0 ? '+' : ''}{me.goal_difference})</span>
                  )}
                </span>
                <span>
                  {settings?.phase === 'league'
                    ? `${remaining} to play`
                    : settings?.phase === 'playoffs' ? 'Playoffs are live' : 'Season over'}
                </span>
              </div>
            </div>
          </section>
        ) : (
          <section className="section">
            <AddTeamForm />
          </section>
        )}

        {awaitingOthers.length > 0 && (
          <section className="section">
            <div className="eyebrow">Waiting on your opponent</div>
            <div className="stack">
              {awaitingOthers.map((match) => {
                const other = league.teamById(match.team_a === myTeam?.id ? match.team_b : match.team_a)
                const mineFirst = match.team_a === myTeam?.id
                return (
                  <div key={match.id} className="card spread" style={{ padding: '14px 16px' }}>
                    <div style={{ minWidth: 0 }}>
                      <div style={{ fontSize: 15 }}>
                        vs {other?.name ?? 'Unknown'}{' '}
                        <span className="muted">
                          {mineFirst ? match.score_a : match.score_b}–{mineFirst ? match.score_b : match.score_a}
                        </span>
                      </div>
                      <div style={{ fontSize: 12, color: 'var(--text-3)' }}>Sent {timeAgo(match.created_at)}</div>
                    </div>
                    <button
                      className="btn btn--quiet btn--sm"
                      disabled={busyId === match.id}
                      onClick={() => act(match.id, () => cancelSubmission(match.id), 'Submission taken back.')}
                    >
                      Undo
                    </button>
                  </div>
                )
              })}
            </div>
          </section>
        )}
      </div>

      {/* The table is the point of the page. */}
      <div className="home__col">
        <section className="section">
          <div className="spread" style={{ marginBottom: 12 }}>
            <div>
              <h1 style={{ fontSize: 22, fontWeight: 500, letterSpacing: '-0.02em', margin: 0 }}>
                League Table
              </h1>
              <div style={{ fontSize: 12.5, color: 'var(--text-3)' }}>
                {settings?.phase === 'league' ? 'Win 3 · Draw 1 · Loss 0' : 'League phase closed'}
              </div>
            </div>
            <span className="pill pill--live">Live</span>
          </div>

          {standings.length === 0 ? (
            <div className="card center muted" style={{ padding: 30, fontSize: 14 }}>
              No teams yet. The table fills in as people pair up.
            </div>
          ) : (
            <div className="card card--flat">
              <div className="tbl__head">
                <span style={{ textAlign: 'center' }}>#</span>
                <span>Team</span>
                <span className="tbl__cell">P</span>
                <span className="tbl__cell">W</span>
                <span className="tbl__cell">T</span>
                <span className="tbl__cell">L</span>
                <span className="tbl__cell">GF</span>
                <span className="tbl__cell">GA</span>
                <span className="tbl__cell">GD</span>
                <span style={{ textAlign: 'right' }}>Pts</span>
              </div>

              {standings.map((row) => {
                const isMe = row.team_id === myTeam?.id
                const atCutline = showCutline && row.rank === qualifying
                return (
                  <div
                    key={row.team_id}
                    className={`tbl__row${isMe ? ' tbl__row--me' : ''}${row.rank === 1 ? ' tbl__row--top' : ''}`}
                    style={atCutline ? { borderBottom: '1px dashed rgba(181,168,255,0.42)' } : undefined}
                  >
                    <span className="tbl__rank">{row.rank}</span>
                    <span style={{ minWidth: 0 }}>
                      <span className="tbl__name">{row.name}</span>
                      <span className="tbl__sub">
                        {row.won}-{row.drawn}-{row.lost} · {row.goals_for}:{row.goals_against} ·{' '}
                        {row.goal_difference > 0 ? '+' : ''}{row.goal_difference}
                      </span>
                    </span>
                    <span className="tbl__cell">{row.played}</span>
                    <span className="tbl__cell">{row.won}</span>
                    <span className="tbl__cell">{row.drawn}</span>
                    <span className="tbl__cell">{row.lost}</span>
                    <span className="tbl__cell">{row.goals_for}</span>
                    <span className="tbl__cell">{row.goals_against}</span>
                    <span className="tbl__cell">
                      {row.goal_difference > 0 ? '+' : ''}{row.goal_difference}
                    </span>
                    <span className="tbl__pts">{row.points}</span>
                  </div>
                )
              })}
            </div>
          )}

          {showCutline && (
            <p style={{ fontSize: 12, color: 'var(--text-3)', margin: '10px 2px 0' }}>
              The dashed line is the playoff cut — top {qualifying} qualify.
            </p>
          )}
          <p style={{ fontSize: 12, color: 'var(--text-3)', margin: '8px 2px 0' }}>
            Level on points? Goal difference decides, then goals scored.
          </p>
        </section>
      </div>
    </div>
  )
}

function Stat({ label, value, accent }: { label: string; value: string; accent?: boolean }) {
  return (
    <div>
      <div className="eyebrow" style={{ margin: '0 0 4px' }}>{label}</div>
      <div style={{ fontSize: 26, fontWeight: 700, letterSpacing: '-0.02em', lineHeight: 1.1, color: accent ? 'var(--accent)' : 'var(--text)' }}>
        {value}
      </div>
    </div>
  )
}

function PendingCard({
  match, busy, onConfirm, onDispute,
}: {
  match: Match; busy: boolean; onConfirm: () => void; onDispute: () => void
}) {
  const league = useLeague()
  const myTeamId = league.myTeam?.id
  const mineFirst = match.team_a === myTeamId
  const myScore = (mineFirst ? match.score_a : match.score_b) ?? 0
  const theirScore = (mineFirst ? match.score_b : match.score_a) ?? 0
  const other = league.teamById(mineFirst ? match.team_b : match.team_a)
  const won = myScore > theirScore

  return (
    <div className="card card--accent">
      <div className="spread" style={{ marginBottom: 14 }}>
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 15, fontWeight: 500 }}>{other?.name ?? 'Unknown'} says:</div>
          <div style={{ fontSize: 12, color: 'var(--text-3)' }}>
            {match.phase === 'playoff' ? 'Playoff game' : 'League game'} · {timeAgo(match.created_at)}
          </div>
        </div>
        <span className="pill pill--accent">{won ? 'You won' : myScore === theirScore ? 'Draw' : 'You lost'}</span>
      </div>

      <div className="center" style={{ fontSize: 40, fontWeight: 700, letterSpacing: '-0.03em', marginBottom: 4 }}>
        {myScore} <span className="dim" style={{ fontSize: 26 }}>–</span> {theirScore}
      </div>
      <div className="center" style={{ fontSize: 12, color: 'var(--text-3)', marginBottom: 16 }}>
        You · {other?.name ?? 'Them'}
      </div>

      <button className="btn btn--primary btn--block" disabled={busy} onClick={onConfirm}>
        <span style={{ width: 17, height: 17, display: 'block' }}><IconCheck /></span>
        {busy ? 'Confirming…' : "That's right — confirm"}
      </button>
      <button className="btn btn--quiet btn--block" disabled={busy} onClick={onDispute} style={{ marginTop: 4 }}>
        Wrong score — flag it
      </button>
    </div>
  )
}
