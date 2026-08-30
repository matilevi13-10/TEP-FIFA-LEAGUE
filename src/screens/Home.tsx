import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '../lib/auth'
import { slotsUsed, useLeague } from '../lib/league'
import { cancelSubmission, confirmMatch, disputeMatch } from '../lib/actions'
import { useToast } from '../components/Toast'
import { IconCheck, IconTrophy } from '../components/Icons'
import { haptic, money, ordinal, timeAgo } from '../lib/format'
import { readableError } from '../lib/supabase'
import type { Match } from '../lib/types'

export function Home() {
  const { team } = useAuth()
  const league = useLeague()
  const toast = useToast()
  const [busyId, setBusyId] = useState<string | null>(null)

  if (!team) return null
  const { settings, standings, matches, pendingForMe, awaitingOthers, potCents, activeTeams } = league

  const me = standings.find((row) => row.team_id === team.id)
  const used = slotsUsed(matches, team.id)
  const total = settings?.games_per_team ?? 0
  const remaining = Math.max(0, total - used)
  const champion = league.teamById(settings?.champion_team_id)

  const myRecent = matches
    .filter((m) => m.status === 'confirmed' && (m.team_a === team.id || m.team_b === team.id))
    .slice(0, 6)

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
              <div style={{ fontSize: 13, color: 'var(--text-2)' }}>
                Takes the {money(potCents)} pot.
              </div>
            </div>
          </div>
        )}

        {/* Anything waiting on this team sits above everything else, in accent. */}
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

      </div>

      <div className="home__col">
        <section className="section">
          <div className="eyebrow">{team.name}</div>
          <div className="card">
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 10 }}>
              <Stat label="Rank" value={me ? ordinal(me.rank) : '—'} accent />
              <Stat label="Record" value={me ? `${me.won}-${me.drawn}-${me.lost}` : '0-0-0'} />
              <Stat label="Points" value={me ? String(me.points) : '0'} />
            </div>

            <div className="divider" style={{ margin: '16px 0 14px' }} />

            <div className="spread" style={{ fontSize: 13 }}>
              <span className="muted">Games played</span>
              <span style={{ fontWeight: 500 }}>
                {me?.played ?? 0} <span className="dim">of {total}</span>
              </span>
            </div>
            <div
              style={{
                height: 6, borderRadius: 3, background: 'rgba(255,255,255,0.07)',
                marginTop: 10, overflow: 'hidden',
              }}
            >
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
                  : settings?.phase === 'playoffs'
                    ? 'Playoffs are live'
                    : 'Season over'}
              </span>
            </div>
          </div>
        </section>

        {awaitingOthers.length > 0 && (
          <section className="section">
            <div className="eyebrow">Waiting on your opponent</div>
            <div className="stack">
              {awaitingOthers.map((match) => {
                const other = league.teamById(match.team_a === team.id ? match.team_b : match.team_a)
                const mineFirst = match.team_a === team.id
                return (
                  <div key={match.id} className="card spread" style={{ padding: '14px 16px' }}>
                    <div style={{ minWidth: 0 }}>
                      <div style={{ fontSize: 15 }}>
                        vs {other?.name ?? 'Unknown'}{' '}
                        <span className="muted">
                          {mineFirst ? match.score_a : match.score_b}–{mineFirst ? match.score_b : match.score_a}
                        </span>
                      </div>
                      <div style={{ fontSize: 12, color: 'var(--text-3)' }}>
                        Sent {timeAgo(match.created_at)}
                      </div>
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

        <section className="section">
          <div className="spread" style={{ marginBottom: 10 }}>
            <div className="eyebrow" style={{ margin: '0 0 0 2px' }}>Recent results</div>
            <Link to="/table" className="btn btn--quiet btn--sm" style={{ padding: 0 }}>Full table</Link>
          </div>
          {myRecent.length === 0 ? (
            <div className="card center" style={{ padding: '26px 18px' }}>
              <p className="muted" style={{ margin: '0 0 14px', fontSize: 14 }}>
                No games logged yet.
              </p>
              <Link to="/submit" className="btn btn--primary">Submit your first result</Link>
            </div>
          ) : (
            <div className="card card--flat">
              {myRecent.map((match, index) => {
                const mineFirst = match.team_a === team.id
                const myScore = (mineFirst ? match.score_a : match.score_b) ?? 0
                const theirScore = (mineFirst ? match.score_b : match.score_a) ?? 0
                const other = league.teamById(mineFirst ? match.team_b : match.team_a)
                const outcome = myScore > theirScore ? 'W' : myScore === theirScore ? 'T' : 'L'
                return (
                  <div
                    key={match.id}
                    className="spread"
                    style={{
                      padding: '13px 16px',
                      borderTop: index === 0 ? 'none' : '1px solid var(--line)',
                    }}
                  >
                    <div className="row" style={{ gap: 11, minWidth: 0 }}>
                      <Outcome value={outcome} />
                      <div style={{ minWidth: 0 }}>
                        <div style={{ fontSize: 14, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                          {other?.name ?? 'Unknown'}
                        </div>
                        <div style={{ fontSize: 11.5, color: 'var(--text-3)' }}>
                          {match.phase === 'playoff' ? 'Playoff' : 'League'} ·{' '}
                          {timeAgo(match.confirmed_at ?? match.created_at)}
                        </div>
                      </div>
                    </div>
                    <div style={{ fontSize: 16, fontWeight: 500 }}>
                      {myScore}–{theirScore}
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </section>
      </div>
    </div>
  )
}

function Stat({ label, value, accent }: { label: string; value: string; accent?: boolean }) {
  return (
    <div>
      <div className="eyebrow" style={{ margin: '0 0 4px' }}>{label}</div>
      <div
        style={{
          fontSize: 26, fontWeight: 700, letterSpacing: '-0.02em', lineHeight: 1.1,
          color: accent ? 'var(--accent)' : 'var(--text)',
        }}
      >
        {value}
      </div>
    </div>
  )
}

function Outcome({ value }: { value: 'W' | 'T' | 'L' }) {
  const style =
    value === 'W'
      ? { background: 'rgba(181,168,255,0.16)', color: 'var(--accent)', border: '1px solid rgba(181,168,255,0.34)' }
      : value === 'T'
        ? { background: 'rgba(255,255,255,0.07)', color: 'var(--text-2)', border: '1px solid var(--line)' }
        : { background: 'transparent', color: 'var(--text-3)', border: '1px solid var(--line)' }
  return (
    <span
      style={{
        ...style, width: 27, height: 27, borderRadius: 9, flexShrink: 0,
        display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
        fontSize: 12, fontWeight: 700,
      }}
    >
      {value}
    </span>
  )
}

function PendingCard({
  match, busy, onConfirm, onDispute,
}: {
  match: Match
  busy: boolean
  onConfirm: () => void
  onDispute: () => void
}) {
  const { team } = useAuth()
  const league = useLeague()
  const mineFirst = match.team_a === team?.id
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

      <div
        className="center"
        style={{ fontSize: 40, fontWeight: 700, letterSpacing: '-0.03em', marginBottom: 4 }}
      >
        {myScore} <span className="dim" style={{ fontSize: 26 }}>–</span> {theirScore}
      </div>
      <div className="center" style={{ fontSize: 12, color: 'var(--text-3)', marginBottom: 16 }}>
        You · {other?.name ?? 'Them'}
      </div>

      <button className="btn btn--primary btn--block" disabled={busy} onClick={onConfirm}>
        <span style={{ width: 17, height: 17, display: 'block' }}><IconCheck /></span>
        {busy ? 'Confirming…' : "That's right — confirm"}
      </button>
      <button
        className="btn btn--quiet btn--block"
        disabled={busy}
        onClick={onDispute}
        style={{ marginTop: 4 }}
      >
        Wrong score — flag it
      </button>
    </div>
  )
}
