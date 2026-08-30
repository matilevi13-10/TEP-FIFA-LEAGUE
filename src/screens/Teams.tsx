import { useAuth } from '../lib/auth'
import { useLeague } from '../lib/league'
import { AddTeamForm } from '../components/AddTeamForm'

export function Teams() {
  const { player } = useAuth()
  const league = useLeague()

  if (!player) return null
  const { teams, pool, playersFor } = league
  const waiting = pool.filter((p) => p.id !== player.id)

  return (
    <div className="page">
      <div className="section" style={{ marginBottom: 18 }}>
        <h1 style={{ fontSize: 26, fontWeight: 500, letterSpacing: '-0.02em', margin: 0 }}>Teams</h1>
        <div style={{ fontSize: 13, color: 'var(--text-3)' }}>
          {teams.length} {teams.length === 1 ? 'team' : 'teams'}
          {waiting.length > 0 && ` · ${waiting.length} without one`}
        </div>
      </div>

      {player.team_id === null && player.is_active && (
        <section className="section"><AddTeamForm /></section>
      )}

      <section className="section">
        <div className="eyebrow">Teams</div>
        {teams.length === 0 ? (
          <div className="card center muted" style={{ padding: 28, fontSize: 14 }}>
            No teams yet.
          </div>
        ) : (
          <div className="grid-cards">
            {teams.map((team) => {
              const roster = playersFor(team.id)
              const mine = team.id === player.team_id
              return (
                <div key={team.id} className={`card${mine ? ' card--accent' : ''}`} style={{ padding: '16px 17px' }}>
                  <div className="spread" style={{ marginBottom: 8 }}>
                    <span style={{ fontSize: 16, fontWeight: 500, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                      {team.name}
                    </span>
                    {mine && <span className="pill pill--accent" style={{ flexShrink: 0 }}>You</span>}
                  </div>
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                    {roster.map((name) => <span key={name} className="pill">{name}</span>)}
                    {roster.length < 2 && <span className="pill dim">Needs a player</span>}
                  </div>
                  {!team.is_active && (
                    <div style={{ fontSize: 12, color: 'var(--text-3)', marginTop: 8 }}>
                      Not counted in the table
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        )}
      </section>

      <section className="section">
        <div className="eyebrow">Not on a team</div>
        {waiting.length === 0 ? (
          <div className="card center muted" style={{ padding: 28, fontSize: 14 }}>
            Everyone has a team.
          </div>
        ) : (
          <div className="stack">
            {waiting.map((other) => (
              <div key={other.id} className="card spread" style={{ padding: '13px 16px' }}>
                <div style={{ minWidth: 0 }}>
                  <div style={{ fontSize: 15, fontWeight: 500 }}>{other.name}</div>
                  <div style={{ fontSize: 12, color: 'var(--text-3)' }}>
                    {other.user_id ? 'Signed up · free to be picked' : 'Named by someone, not signed up yet'}
                  </div>
                </div>
                {!other.user_id && <span className="pill" style={{ flexShrink: 0 }}>Placeholder</span>}
              </div>
            ))}
          </div>
        )}
      </section>
    </div>
  )
}
