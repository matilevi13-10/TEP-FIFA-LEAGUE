import { describeSeason, useLeague } from '../lib/league'

/**
 * The league rules, as agreed in the group chat. The schedule, the table and
 * the bracket enforce the ones they can; the rest are on trust.
 */
export function Rules() {
  const { activeTeams, settings, schedule } = useLeague()
  const n = activeTeams.length
  const games = settings?.games_per_team ?? 0

  const rules = [
    describeSeason(n, games, schedule.length ? new Set(schedule.map((m) => m.round)).size : undefined)
      .replace(/ With \d+ teams, an odd number.*$/, ''),
    'Each round is one opponent, played twice that week — one home game each.',
    '5-minute halves, World Class difficulty.',
    'Pick your own team for every game. The home team picks their team and the console.',
    'Tied after 90 minutes? Classic extra time. Still tied, and it stays a tie — a point each. Penalties never count toward the score.',
    'Enter scores exactly right. Goal difference, then goals scored, break ties in the table.',
    n % 2 === 1
      ? 'Everyone makes the playoffs. The #1 seed gets a first-round bye.'
      : 'Everyone makes the playoffs.',
    'Playoff scores are entered by one team and confirmed by the other.',
    'Playoff ties are two legs on aggregate; the final is one game. Level on aggregate, or a level final? Penalties decide who goes through — the score stays a tie.',
  ]

  return (
    <section className="section">
      <div className="eyebrow">League rules</div>
      <div className="card card--flat">
        {rules.map((rule, i) => (
          <div
            key={rule}
            className="t-subhead"
            style={{
              padding: 'var(--s-3) var(--s-4)',
              borderTop: i === 0 ? 'none' : '1px solid var(--sep)',
            }}
          >
            {rule}
          </div>
        ))}
      </div>
    </section>
  )
}
