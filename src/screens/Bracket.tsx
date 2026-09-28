import { tieResult, useLeague } from '../lib/league'
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
              {settings?.playoff_size} teams · two legs on aggregate, one-game final · winner takes {money(potCents)}
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
            // One tie per slot, holding its one or two legs.
            const ties = new Map<number, Match[]>()
            for (const m of playoffMatches.filter((m) => m.round === round)) {
              ties.set(m.slot ?? 0, [...(ties.get(m.slot ?? 0) ?? []), m].sort((a, b) => a.leg - b.leg))
            }
            const inRound = [...ties.entries()].sort(([a], [b]) => a - b).map(([, legs]) => legs)

            // Pair adjacent slots so the connector can draw a single riser.
            const pairs: Match[][][] = []
            for (let i = 0; i < inRound.length; i += 2) pairs.push(inRound.slice(i, i + 2))

            return (
              <div className="bracket__round" key={round}>
                <div className="bracket__title">{roundName(round, totalRounds)}</div>
                {pairs.map((pair, index) => (
                  <div
                    key={index}
                    className={`bracket__pair${pair.length === 2 ? ' bracket__pair--two' : ''}`}
                  >
                    {pair.map((legs) => (
                      <div className="bracket__slot" key={legs[0].id}>
                        <Matchup legs={legs} myTeamId={league.myTeam?.id} />
                      </div>
                    ))}
                  </div>
                ))}
              </div>
            )
          })}
        </div>

        <p className="t-caption dim" style={{ margin: 'var(--s-3) var(--s-1) 0' }}>
          Swipe across to follow the bracket. Seeds come from the final league table;
          the higher seed hosts the second leg and the final.
        </p>
      </section>
    </div>
  )
}

function Matchup({ legs, myTeamId }: { legs: Match[]; myTeamId?: string }) {
  const league = useLeague()
  const first = legs[0]
  const teamA = league.teamById(first.team_a)
  const teamB = league.teamById(first.team_b)
  const bye = first.status === 'bye'
  const result = tieResult(legs)
  const settled = result.winner !== null
  const mine = myTeamId && (first.team_a === myTeamId || first.team_b === myTeamId)

  const sideClass = (isTeamA: boolean) => {
    if (!settled) return ''
    const id = isTeamA ? first.team_a : first.team_b
    return id === result.winner ? ' matchup__side--won' : ' matchup__side--lost'
  }

  const legLine = legs.length === 2
    ? legs
        .map((m) => `Leg ${m.leg} ${m.status === 'confirmed' ? `${m.score_a}–${m.score_b}` : 'to play'}`)
        .join(' · ') + (result.onPenalties ? ' · won on pens' : '')
    : result.onPenalties ? 'Won on penalties' : null

  const note =
    bye ? 'Bye — straight through'
      : legs.some((m) => m.status === 'disputed') ? 'Disputed — admin to settle'
      : legs.some((m) => m.status === 'pending') ? 'Awaiting confirmation'
      : !first.team_a || !first.team_b ? 'Waiting on the round before'
      : legLine ?? (settled ? null : 'Not played yet')

  return (
    <div className={`matchup${mine && !settled ? ' matchup--live' : ''}${settled ? ' matchup--done' : ''}`}>
      <Side
        seed={first.seed_a} name={teamA?.name} score={result.confirmed ? result.aggA : null}
        highlight={first.team_a === myTeamId} className={sideClass(true)}
      />
      <Side
        seed={first.seed_b} name={bye ? 'Bye' : teamB?.name} score={result.confirmed ? result.aggB : null}
        highlight={first.team_b === myTeamId} className={sideClass(false)}
      />
      {note && <div className="matchup__foot"><span>{note}</span></div>}
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
