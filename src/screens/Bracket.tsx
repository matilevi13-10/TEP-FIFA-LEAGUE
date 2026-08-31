import { useLeague } from '../lib/league'
import { IconTrophy } from '../components/Icons'
import { money, roundName } from '../lib/format'
import type { Match } from '../lib/types'

export function Bracket() {
  const league = useLeague()
  const { matches, settings, potCents } = league

  const playoffMatches = matches.filter((m) => m.phase === 'playoff')
  const champion = league.teamById(settings?.champion_team_id)

  if (playoffMatches.length === 0) {
    return (
      <div className="page">
        <div className="section">
          <h1 className="t-title" style={{ margin: '0 0 var(--s-4)' }}>Bracket</h1>
          <div className="card center muted t-subhead" style={{ padding: 'var(--s-8) var(--s-4)' }}>
            The playoffs haven't started yet.
          </div>
        </div>
      </div>
    )
  }

  const rounds = [...new Set(playoffMatches.map((m) => m.round ?? 0))].sort((a, b) => a - b)
  const totalRounds = rounds.length

  return (
    <div className="page">
      <section className="section">
        <div className="spread" style={{ marginBottom: 'var(--s-4)' }}>
          <div>
            <h1 className="t-title" style={{ margin: 0 }}>Bracket</h1>
            <div className="t-foot dim">
              {settings?.playoff_size}-team single elimination · winner takes {money(potCents)}
            </div>
          </div>
          {settings?.phase === 'playoffs' && <span className="pill pill--live">Live</span>}
        </div>

        {champion && (
          <div className="card card--accent row" style={{ marginBottom: 'var(--s-4)' }}>
            <span style={{ width: '1.875rem', height: '1.875rem', color: 'var(--accent)', flexShrink: 0 }}>
              <IconTrophy />
            </span>
            <div>
              <div className="eyebrow eyebrow--accent" style={{ margin: 0 }}>Champions</div>
              <div className="t-title-2">{champion.name}</div>
            </div>
          </div>
        )}

        <div className="bracket">
          {rounds.map((round) => {
            const inRound = playoffMatches
              .filter((m) => m.round === round)
              .sort((a, b) => (a.slot ?? 0) - (b.slot ?? 0))

            // Pair adjacent slots so the connector can draw a single riser.
            const pairs: Match[][] = []
            for (let i = 0; i < inRound.length; i += 2) pairs.push(inRound.slice(i, i + 2))

            return (
              <div className="bracket__round" key={round}>
                <div className="bracket__title">{roundName(round, totalRounds)}</div>
                {pairs.map((pair, index) => (
                  <div
                    key={index}
                    className={`bracket__pair${pair.length === 2 ? ' bracket__pair--two' : ''}`}
                  >
                    {pair.map((match) => (
                      <div className="bracket__slot" key={match.id}>
                        <Matchup match={match} myTeamId={league.myTeam?.id} />
                      </div>
                    ))}
                  </div>
                ))}
              </div>
            )
          })}
        </div>

        <p className="t-caption dim" style={{ margin: 'var(--s-3) var(--s-1) 0' }}>
          Swipe across to follow the bracket. Seeds come from the final league table.
        </p>
      </section>
    </div>
  )
}

function Matchup({ match, myTeamId }: { match: Match; myTeamId?: string }) {
  const league = useLeague()
  const teamA = league.teamById(match.team_a)
  const teamB = league.teamById(match.team_b)
  const settled = match.status === 'confirmed'
  const mine = myTeamId && (match.team_a === myTeamId || match.team_b === myTeamId)

  const sideClass = (isTeamA: boolean) => {
    if (!settled || match.winner_id === null) return ''
    const id = isTeamA ? match.team_a : match.team_b
    return id === match.winner_id ? ' matchup__side--won' : ' matchup__side--lost'
  }

  const note =
    match.status === 'pending'
      ? 'Awaiting confirmation'
      : match.status === 'disputed'
        ? 'Disputed — admin to settle'
        : match.team_a && match.team_b
          ? 'Not played yet'
          : 'Waiting on the round before'

  return (
    <div className={`matchup${mine && !settled ? ' matchup--live' : ''}${settled ? ' matchup--done' : ''}`}>
      <Side
        seed={match.seed_a} name={teamA?.name} score={match.score_a}
        highlight={match.team_a === myTeamId} className={sideClass(true)}
      />
      <Side
        seed={match.seed_b} name={teamB?.name} score={match.score_b}
        highlight={match.team_b === myTeamId} className={sideClass(false)}
      />
      {!settled && <div className="matchup__foot"><span>{note}</span></div>}
    </div>
  )
}

function Side({
  seed, name, score, highlight, className,
}: {
  seed: number | null
  name?: string
  score: number | null
  highlight?: boolean
  className: string
}) {
  return (
    <div className={`matchup__side${className}`}>
      <span className="matchup__seed">{seed ?? ''}</span>
      <span
        className="matchup__team"
        style={highlight ? { fontWeight: 600 } : undefined}
      >
        {name ?? <span className="dim">—</span>}
      </span>
      <span className="matchup__score">{score ?? ''}</span>
    </div>
  )
}
