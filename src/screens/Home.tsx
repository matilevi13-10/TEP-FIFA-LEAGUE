import { useState } from 'react'
import { useAuth } from '../lib/auth'
import { fixtureLabel, useLeague } from '../lib/league'
import { cancelSubmission, confirmMatch, disputeMatch } from '../lib/actions'
import { IncomingRequests } from '../components/IncomingRequests'
import { TeamFormed } from '../components/TeamFormed'
import { NextMatch } from '../components/NextMatch'
import { TeamFormation } from '../components/TeamFormation'
import { TeamNameEditor } from '../components/TeamNameEditor'
import { Rules } from '../components/Rules'
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
  const [formed, setFormed] = useState<string | null>(null)

  if (!player) return null
  const { settings, standings, pendingForMe, awaitingOthers, potCents, activeTeams, myTeam } = league

  const me = myTeam ? standings.find((row) => row.team_id === myTeam.id) : undefined
  // Games remaining is now what the schedule actually says, not a setting.
  const mySchedule = league.myFixtures
  const total = mySchedule.length || (settings?.games_per_team ?? 0)
  const remaining = mySchedule.filter(
    (m) => m.status === 'scheduled' || m.status === 'pending' || m.status === 'disputed',
  ).length
  const champion = league.teamById(settings?.champion_team_id)

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
      {/* Spans both columns so it is the first thing on the page at any width. */}
      {!myTeam && (
        <div className="home__hero">
          <IncomingRequests onAccepted={(teamName) => setFormed(teamName)} />
        </div>
      )}
      {formed && <TeamFormed teamName={formed} onDone={() => setFormed(null)} />}

      <div className="home__col">
        {champion && (
          <div className="card card--accent section row">
            <span style={{ width: '1.875rem', height: '1.875rem', color: 'var(--accent)', flexShrink: 0 }}>
              <IconTrophy />
            </span>
            <div>
              <div className="eyebrow eyebrow--accent" style={{ margin: 0 }}>Champions</div>
              <div className="t-title-2">{champion.name}</div>
              <div className="t-foot muted">Takes the {money(potCents)} pot.</div>
            </div>
          </div>
        )}

        {pendingForMe.length > 0 && (
          <section className="section">
            <div className="eyebrow eyebrow--accent">
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
          <div className="card card--accent center" style={{ padding: 'var(--s-6) var(--s-4)' }}>
            <div className="eyebrow" style={{ margin: 0 }}>Grand prize</div>
            <div
              className="t-display"
              style={{ color: 'var(--accent)', textShadow: '0 0 46px rgba(181,168,255,0.42)', margin: 'var(--s-1) 0' }}
            >
              {money(potCents)}
            </div>
            <div className="t-foot muted">
              {activeTeams.length} {activeTeams.length === 1 ? 'team' : 'teams'} ×{' '}
              {money(settings?.buy_in_cents ?? 0)} buy-in
            </div>
          </div>
        </section>

        {myTeam && <NextMatch />}

        {myTeam ? (
          <section className="section">
            <TeamNameEditor team={myTeam} />
            <div className="card">
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 'var(--s-3)' }}>
                <Stat label="Rank" value={me ? ordinal(me.rank) : '—'} accent />
                <Stat label="Record" value={me ? `${me.won}-${me.drawn}-${me.lost}` : '0-0-0'} />
                <Stat label="Points" value={me ? String(me.points) : '0'} />
              </div>

              <div className="divider" style={{ margin: 'var(--s-4) 0 var(--s-3)' }} />

              <div className="spread t-foot">
                <span className="muted">Games played</span>
                <span style={{ fontWeight: 600 }}>{me?.played ?? 0} <span className="dim">of {total}</span></span>
              </div>
              <div style={{ height: '0.375rem', borderRadius: 'var(--r-full)', background: 'var(--fill-2)', marginTop: 'var(--s-2)', overflow: 'hidden' }}>
                <div
                  style={{
                    height: '100%', width: `${total ? Math.min(100, ((me?.played ?? 0) / total) * 100) : 0}%`,
                    background: 'var(--accent)', boxShadow: 'var(--sh-accent)',
                    borderRadius: 'var(--r-full)',
                    transition: 'width var(--dur-standard) var(--ease-standard)',
                  }}
                />
              </div>
              <div className="spread t-caption dim" style={{ marginTop: 'var(--s-2)' }}>
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
          <TeamFormation />
        )}

        {awaitingOthers.length > 0 && (
          <section className="section">
            <div className="eyebrow">Waiting on your opponent</div>
            <div className="stack">
              {awaitingOthers.map((match) => {
                const other = league.teamById(match.team_a === myTeam?.id ? match.team_b : match.team_a)
                const mineFirst = match.team_a === myTeam?.id
                return (
                  <div key={match.id} className="card spread">
                    <div style={{ minWidth: 0 }}>
                      <div className="t-subhead">
                        vs {other?.name ?? 'Unknown'}{' '}
                        <span className="muted num">
                          {mineFirst ? match.score_a : match.score_b}–{mineFirst ? match.score_b : match.score_a}
                        </span>
                      </div>
                      <div className="t-caption dim">Sent {timeAgo(match.created_at)}</div>
                    </div>
                    <button
                      className="btn btn--plain btn--sm"
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
          <div className="spread" style={{ marginBottom: 'var(--s-3)' }}>
            <div>
              <h1 className="t-title-2" style={{ margin: 0 }}>League Table</h1>
              <div className="t-foot dim">
                {settings?.phase === 'league' ? 'Win 3 · Draw 1 · Loss 0' : 'League phase closed'}
              </div>
            </div>
            <span className="pill pill--live">Live</span>
          </div>

          {standings.length === 0 ? (
            <div className="card center muted t-subhead" style={{ padding: 'var(--s-8) var(--s-4)' }}>
              No teams yet. The table fills in as people pair up.
            </div>
          ) : (
            <div className="card card--flat tbl">
              <div className="tbl__head">
                <span style={{ textAlign: 'center' }}>#</span>
                <span>Team</span>
                <span className="tbl__cell">P</span>
                <span className="tbl__cell">W</span>
                <span className="tbl__cell">D</span>
                <span className="tbl__cell">L</span>
                <span className="tbl__cell">GF</span>
                <span className="tbl__cell">GA</span>
                <span className="tbl__cell">GD</span>
                <span style={{ textAlign: 'right' }}>Pts</span>
              </div>

              {standings.map((row) => {
                const isMe = row.team_id === myTeam?.id
                return (
                  <div
                    key={row.team_id}
                    className={`tbl__row${isMe ? ' tbl__row--me' : ''}${row.rank === 1 ? ' tbl__row--top' : ''}`}
                  >
                    <span className="tbl__rank">{row.rank}</span>
                    <span style={{ minWidth: 0 }}>
                      <span className="tbl__name">{row.name}</span>
                      <span className="tbl__sub">
                        {row.won}W-{row.drawn}D-{row.lost}L · {row.goals_for}:{row.goals_against} ·{' '}
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

          <p className="t-caption dim" style={{ margin: 'var(--s-2) var(--s-1) 0' }}>
            Everyone makes the playoffs{standings.length % 2 === 1 ? ' — #1 gets a first-round bye' : ''}.
            Level on points? Goal difference decides, then goals scored.
          </p>
        </section>

        <Rules />
      </div>
    </div>
  )
}

function Stat({ label, value, accent }: { label: string; value: string; accent?: boolean }) {
  return (
    <div>
      <div className="eyebrow" style={{ margin: '0 0 var(--s-1)' }}>{label}</div>
      <div className="t-title" style={{ color: accent ? 'var(--accent)' : 'var(--text)' }}>{value}</div>
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
  const drawn = myScore === theirScore

  return (
    <div className="card card--accent">
      <div className="spread" style={{ marginBottom: 'var(--s-4)' }}>
        <div style={{ minWidth: 0 }}>
          <div className="t-headline">{other?.name ?? 'Unknown'} says:</div>
          <div className="t-caption dim">
            {fixtureLabel(match, league.matches)} · {timeAgo(match.created_at)}
          </div>
        </div>
        <span className="pill pill--accent">{won ? 'You won' : drawn ? 'Tie' : 'You lost'}</span>
      </div>

      <div className="center num" style={{ fontSize: '2.5rem', fontWeight: 700, letterSpacing: '-0.03em', lineHeight: 1.1 }}>
        {myScore} <span className="dim" style={{ fontSize: '1.625rem' }}>–</span> {theirScore}
      </div>
      <div className="center t-caption dim" style={{ marginBottom: 'var(--s-4)' }}>
        You · {other?.name ?? 'Them'}
        {match.shootout_winner && (
          <> · {match.shootout_winner === myTeamId ? 'you' : other?.name ?? 'they'} won on penalties</>
        )}
      </div>

      <button className="btn btn--primary btn--block" disabled={busy} onClick={onConfirm}>
        <span className="btn__glyph"><IconCheck /></span>
        {busy ? 'Confirming…' : "That's right — confirm"}
      </button>
      <button className="btn btn--plain btn--block" disabled={busy} onClick={onDispute} style={{ marginTop: 'var(--s-1)' }}>
        Wrong score — flag it
      </button>
    </div>
  )
}
