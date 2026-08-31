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
      <div className="section" style={{ marginBottom: 'var(--s-5)' }}>
        <h1 className="t-title" style={{ margin: 0 }}>Teams</h1>
        <div className="t-foot dim">
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
          <div className="card center muted t-subhead" style={{ padding: 'var(--s-7) var(--s-4)' }}>
            No teams yet.
          </div>
        ) : (
          <div className="grid-cards">
            {teams.map((team) => {
              const roster = playersFor(team.id)
              const mine = team.id === player.team_id
              return (
                <div key={team.id} className={`card${mine ? ' card--accent' : ''}`}>
                  <div className="spread" style={{ marginBottom: 'var(--s-3)' }}>
                    <span className="t-headline truncate">{team.name}</span>
                    {mine && <span className="pill pill--accent" style={{ flexShrink: 0 }}>You</span>}
                  </div>
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 'var(--s-2)' }}>
                    {roster.map((name) => <span key={name} className="pill">{name}</span>)}
                    {roster.length < 2 && <span className="pill dim">Needs a player</span>}
                  </div>
                  {!team.is_active && (
                    <div className="t-caption dim" style={{ marginTop: 'var(--s-2)' }}>
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
          <div className="card center muted t-subhead" style={{ padding: 'var(--s-7) var(--s-4)' }}>
            Everyone has a team.
          </div>
        ) : (
          <div className="stack">
            {waiting.map((other) => (
              <div key={other.id} className="card spread">
                <div style={{ minWidth: 0 }}>
                  <div className="t-headline">{other.name}</div>
                  <div className="t-caption dim">
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
