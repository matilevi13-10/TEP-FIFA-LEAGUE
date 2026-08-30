import { useAuth } from '../lib/auth'
import { useLeague } from '../lib/league'

export function TableScreen() {
  const { team } = useAuth()
  const { standings, settings, loading } = useLeague()

  const qualifying = settings?.playoff_size ?? 0
  const showCutline = settings?.phase === 'league' && qualifying > 0 && standings.length > qualifying

  return (
    <div className="page">
      <section className="section">
        <div className="spread" style={{ marginBottom: 12 }}>
          <div>
            <h1 style={{ fontSize: 26, fontWeight: 500, letterSpacing: '-0.02em', margin: 0 }}>
              League Table
            </h1>
            <div style={{ fontSize: 13, color: 'var(--text-3)' }}>
              {settings?.phase === 'league'
                ? `Win 3 · Draw 1 · Loss 0`
                : 'Final standings — the league phase is closed'}
            </div>
          </div>
          <span className="pill pill--live">Live</span>
        </div>

        {loading ? (
          <div className="stack">
            {[0, 1, 2, 3, 4].map((i) => <div key={i} className="skeleton" style={{ height: 56 }} />)}
          </div>
        ) : standings.length === 0 ? (
          <div className="card center muted" style={{ padding: 30 }}>
            No teams yet.
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
              const isMe = row.team_id === team?.id
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
  )
}
