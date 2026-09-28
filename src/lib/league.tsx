import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { supabase } from './supabase'
import { useAuth } from './auth'
import { roundName } from './format'
import type { Match, Message, Player, Settings, Standing, Team, TeamRequest } from './types'

interface LeagueValue {
  loading: boolean
  teams: Team[]
  players: Player[]
  matches: Match[]
  messages: Message[]
  requests: TeamRequest[]
  settings: Settings | null
  standings: Standing[]
  activeTeams: Team[]
  /** Everybody without a team. */
  pool: Player[]
  /** Everyone else in the pool — all of them signed up, so all are askable. */
  availableTeammates: Player[]
  /** Requests sent to me, still open. */
  incomingRequests: TeamRequest[]
  /** My single open outgoing request, if any. */
  outgoingRequest: TeamRequest | undefined
  teamById: (id: string | null | undefined) => Team | undefined
  playerById: (id: string | null | undefined) => Player | undefined
  /** The two player names for a team, in slot order. */
  playersFor: (teamId: string | null | undefined) => string[]
  myTeam: Team | undefined
  /** My team's fixtures in schedule order, played and unplayed. */
  myFixtures: Match[]
  /** The next fixture to play — scheduled or disputed, earliest first. */
  nextFixture: Match | undefined
  /** A fixture of mine waiting on the opponent to confirm. */
  awaitingConfirmation: Match | undefined
  /** The whole league schedule in order. */
  schedule: Match[]
  /** Results submitted against my team that we still have to approve. */
  pendingForMe: Match[]
  /** Results we submitted that the other team has not approved yet. */
  awaitingOthers: Match[]
  potCents: number
  /**
   * Mirrors season_has_started() in schema.sql: the admin opened it, the
   * playoffs began, or a result has actually been confirmed. Leaving a team is
   * only possible while this is false.
   */
  seasonStarted: boolean
  /**
   * The database is missing a migration this app depends on (it still lacks
   * the columns 003_league_rules.sql adds). Everything it computes — the
   * schedule above all — comes from the old functions until that is run.
   */
  schemaOutdated: boolean
  refresh: () => Promise<void>
}

const LeagueContext = createContext<LeagueValue | null>(null)

/**
 * Mirrors the `standings` view in schema.sql: confirmed league games only,
 * win 3, draw 1, loss 0, ordered by points, then goal difference, then goals
 * scored, then name. Computed here too so the table reacts the instant
 * realtime fires.
 */
export function computeStandings(teams: Team[], matches: Match[]): Standing[] {
  const table = new Map<string, Standing>()
  for (const team of teams) {
    if (!team.is_active) continue
    table.set(team.id, {
      team_id: team.id, name: team.name, played: 0, won: 0, drawn: 0, lost: 0,
      goals_for: 0, goals_against: 0, goal_difference: 0, points: 0, rank: 0,
    })
  }

  for (const match of matches) {
    if (match.phase !== 'league' || match.status !== 'confirmed') continue
    if (match.score_a === null || match.score_b === null) continue

    for (const [teamId, gf, ga] of [
      [match.team_a, match.score_a, match.score_b],
      [match.team_b, match.score_b, match.score_a],
    ] as const) {
      const row = teamId ? table.get(teamId) : undefined
      if (!row) continue
      row.played += 1
      row.goals_for += gf
      row.goals_against += ga
      if (gf > ga) { row.won += 1; row.points += 3 }
      else if (gf === ga) { row.drawn += 1; row.points += 1 }
      else row.lost += 1
    }
  }

  const rows = [...table.values()]
  for (const row of rows) row.goal_difference = row.goals_for - row.goals_against
  rows.sort(
    (a, b) =>
      b.points - a.points ||
      b.goal_difference - a.goal_difference ||
      b.goals_for - a.goals_for ||
      a.name.localeCompare(b.name),
  )
  rows.forEach((row, index) => { row.rank = index + 1 })
  return rows
}

/** Week (or bracket round), then pairing, then game 1 before game 2. */
export const bySchedule = (a: Match, b: Match) =>
  (a.round ?? 0) - (b.round ?? 0) || (a.slot ?? 0) - (b.slot ?? 0) || a.leg - b.leg

/** Every league fixture involving a team, in schedule order. */
export function fixturesFor(matches: Match[], teamId: string): Match[] {
  return matches
    .filter((m) => m.phase === 'league' && (m.team_a === teamId || m.team_b === teamId))
    .sort(bySchedule)
}

/** The games of one playoff tie, leg 1 first. */
export function tieLegs(matches: Match[], round: number | null, slot: number | null): Match[] {
  return matches
    .filter((m) => m.phase === 'playoff' && m.round === round && m.slot === slot)
    .sort((a, b) => a.leg - b.leg)
}

/** Mirrors playoff_is_final(): the last round is the final, played as one game. */
export function isFinalRound(matches: Match[], round: number | null): boolean {
  return !matches.some((m) => m.phase === 'playoff' && (m.round ?? 0) > (round ?? 0))
}

/**
 * How long the regular season runs, in words. Mirrors generate_schedule():
 * rounds are games / 2, and with an odd number of teams somebody sits out
 * every week, so the season runs longer than the rounds — 7 teams playing 12
 * games is 6 rounds over 7 weeks. Pass the built schedule's week count when
 * there is one; otherwise an uneven cycle can only be estimated.
 */
export function describeSeason(teams: number, games: number, scheduledWeeks?: number): string {
  const rounds = Math.floor(games / 2)
  if (teams < 2 || rounds < 1) return ''
  if (teams % 2 === 0) {
    return `${games} games per team: ${rounds} rounds over ${scheduledWeeks ?? rounds} weeks — one opponent a week, two games that week.`
  }
  const exact = rounds % (teams - 1) === 0
  const weeks = scheduledWeeks ?? Math.ceil((teams * rounds) / (teams - 1))
  const off = weeks - rounds
  const length = scheduledWeeks || exact ? `${weeks} weeks` : `about ${weeks} weeks`
  const offText = exact || scheduledWeeks
    ? `each team has ${off === 1 ? 'one week' : `${off} weeks`} off`
    : 'with the odd week off'
  // An odd number of teams can't all play an odd number of rounds: somebody
  // is always left without a partner, and ends a round short.
  const short = rounds % 2 === 1
    ? ` With ${teams} teams, an odd number of rounds leaves some teams a round short — ` +
      `${2 * (rounds - 1)} or ${2 * (rounds + 1)} games gives everyone the same number.`
    : ''
  return `${games} games per team: ${rounds} rounds over ${length} — ${offText}.${short}`
}

/** "Week 3 · Game 1 of 2", "Semi-finals · Leg 2 of 2", "Final". */
export function fixtureLabel(match: Match, matches: Match[]): string {
  if (match.phase === 'league') return `Week ${match.round} · Game ${match.leg} of 2`
  const total = Math.max(0, ...matches.filter((m) => m.phase === 'playoff').map((m) => m.round ?? 0))
  const name = roundName(match.round ?? 0, total)
  return isFinalRound(matches, match.round) ? name : `${name} · Leg ${match.leg} of 2`
}

export interface TieResult {
  /** Aggregate over the confirmed legs, from team_a's and team_b's side. */
  aggA: number
  aggB: number
  confirmed: number
  /** Mirrors tie_winner(): set once a bye exists or every leg is confirmed. */
  winner: string | null
  /** True when the winner went through on penalties. */
  onPenalties: boolean
}

/**
 * Mirrors check_playoff_score(): does this score (from team_a's side) leave the
 * final or the aggregate level, so the shootout winner has to be recorded?
 */
export function needsShootout(match: Match, matches: Match[], scoreA: number, scoreB: number): boolean {
  if (match.phase !== 'playoff') return false
  if (isFinalRound(matches, match.round)) return scoreA === scoreB
  const other = tieLegs(matches, match.round, match.slot).find((m) => m.leg !== match.leg)
  if (other?.status !== 'confirmed') return false
  return (other.score_a ?? 0) + scoreA === (other.score_b ?? 0) + scoreB
}

export function tieResult(legs: Match[]): TieResult {
  const bye = legs.find((m) => m.status === 'bye')
  const done = legs.filter((m) => m.status === 'confirmed')
  const aggA = done.reduce((sum, m) => sum + (m.score_a ?? 0), 0)
  const aggB = done.reduce((sum, m) => sum + (m.score_b ?? 0), 0)
  let winner: string | null = bye?.winner_id ?? null
  let onPenalties = false
  if (!bye && legs.length > 0 && done.length === legs.length) {
    if (aggA !== aggB) winner = aggA > aggB ? legs[0].team_a : legs[0].team_b
    else {
      winner = done.find((m) => m.shootout_winner)?.shootout_winner ?? null
      onPenalties = winner !== null
    }
  }
  return { aggA, aggB, confirmed: done.length, winner, onPenalties }
}

export function LeagueProvider({ children }: { children: ReactNode }) {
  const { session, player } = useAuth()
  const [teams, setTeams] = useState<Team[]>([])
  const [players, setPlayers] = useState<Player[]>([])
  const [matches, setMatches] = useState<Match[]>([])
  const [messages, setMessages] = useState<Message[]>([])
  const [requests, setRequests] = useState<TeamRequest[]>([])
  const [settings, setSettings] = useState<Settings | null>(null)
  const [loading, setLoading] = useState(true)
  const [schemaOutdated, setSchemaOutdated] = useState(false)
  const pending = useRef<number | null>(null)

  const refresh = useCallback(async () => {
    if (!session) return
    const [t, p, m, msg, r, s, probe] = await Promise.all([
      supabase.from('teams').select('*').order('name'),
      supabase.from('players').select('*').order('name'),
      supabase.from('matches').select('*').order('created_at', { ascending: false }),
      supabase.from('messages').select('*').order('created_at', { ascending: true }).limit(300),
      supabase.from('team_requests').select('*').eq('status', 'pending'),
      supabase.from('league_settings').select('*').eq('id', 1).maybeSingle(),
      // Asking for the newest columns by name fails with 42703 (undefined
      // column) on a database that has not had 003 run, even with no rows.
      supabase.from('matches').select('leg, shootout_winner').limit(1),
    ])
    if (t.data) setTeams(t.data as Team[])
    if (p.data) setPlayers(p.data as Player[])
    if (m.data) setMatches(m.data as Match[])
    if (msg.data) setMessages(msg.data as Message[])
    if (r.data) setRequests(r.data as TeamRequest[])
    if (s.data) setSettings(s.data as Settings)
    setSchemaOutdated(probe.error?.code === '42703')
    setLoading(false)
  }, [session])

  useEffect(() => {
    if (!session) {
      setTeams([]); setPlayers([]); setMatches([]); setMessages([])
      setRequests([]); setSettings(null); setLoading(true)
      return
    }
    void refresh()

    // Any write lands here within a second on every signed-in phone. The whole
    // dataset is small, so a refetch is simpler and never drifts out of sync
    // the way patching rows in place can.
    const nudge = () => {
      if (pending.current) window.clearTimeout(pending.current)
      pending.current = window.setTimeout(() => void refresh(), 140)
    }

    const channel = supabase.channel('tep-league')
    for (const table of ['matches', 'teams', 'players', 'messages', 'team_requests', 'league_settings']) {
      channel.on('postgres_changes', { event: '*', schema: 'public', table }, nudge)
    }
    channel.subscribe()

    // Phones suspend sockets in the background; re-sync whenever we come back.
    const onVisible = () => { if (document.visibilityState === 'visible') void refresh() }
    document.addEventListener('visibilitychange', onVisible)
    window.addEventListener('online', onVisible)

    return () => {
      if (pending.current) window.clearTimeout(pending.current)
      void supabase.removeChannel(channel)
      document.removeEventListener('visibilitychange', onVisible)
      window.removeEventListener('online', onVisible)
    }
  }, [session, refresh])

  const value = useMemo<LeagueValue>(() => {
    const teamsById = new Map(teams.map((t) => [t.id, t]))
    const playersById = new Map(players.map((p) => [p.id, p]))

    const namesByTeam = new Map<string, string[]>()
    for (const p of [...players].sort((a, b) => (a.slot ?? 0) - (b.slot ?? 0))) {
      if (!p.team_id) continue
      namesByTeam.set(p.team_id, [...(namesByTeam.get(p.team_id) ?? []), p.name])
    }

    const me = player?.id ?? null
    const myTeamId = player?.team_id ?? null
    const activeTeams = teams.filter((t) => t.is_active)

    return {
      loading, teams, players, matches, messages, requests, settings, activeTeams,
      pool: players.filter((p) => p.team_id === null && p.is_active),
      availableTeammates: players.filter(
        (p) => p.team_id === null && p.is_active && p.user_id !== null && p.id !== me,
      ),
      incomingRequests: me ? requests.filter((r) => r.to_player === me) : [],
      outgoingRequest: me ? requests.find((r) => r.from_player === me) : undefined,
      standings: computeStandings(teams, matches),
      teamById: (id) => (id ? teamsById.get(id) : undefined),
      playerById: (id) => (id ? playersById.get(id) : undefined),
      playersFor: (id) => (id ? (namesByTeam.get(id) ?? []) : []),
      myTeam: myTeamId ? teamsById.get(myTeamId) : undefined,
      myFixtures: myTeamId ? fixturesFor(matches, myTeamId) : [],
      nextFixture: myTeamId
        ? fixturesFor(matches, myTeamId).find(
            (m) => m.status === 'scheduled' || m.status === 'disputed',
          )
        : undefined,
      awaitingConfirmation: myTeamId
        ? fixturesFor(matches, myTeamId).find(
            (m) => m.status === 'pending' && m.submitted_by === myTeamId,
          )
        : undefined,
      schedule: matches.filter((m) => m.phase === 'league').sort(bySchedule),
      pendingForMe: myTeamId
        ? matches.filter(
            (m) => m.status === 'pending' && m.submitted_by !== myTeamId &&
                   (m.team_a === myTeamId || m.team_b === myTeamId),
          )
        : [],
      awaitingOthers: myTeamId
        ? matches.filter((m) => m.status === 'pending' && m.submitted_by === myTeamId)
        : [],
      potCents: activeTeams.length * (settings?.buy_in_cents ?? 0),
      seasonStarted:
        Boolean(settings?.season_started_at) ||
        (settings?.phase ?? 'league') !== 'league' ||
        matches.some((m) => m.status === 'confirmed'),
      schemaOutdated,
      refresh,
    }
  }, [loading, teams, players, matches, messages, requests, settings, player, schemaOutdated, refresh])

  return <LeagueContext.Provider value={value}>{children}</LeagueContext.Provider>
}

export function useLeague(): LeagueValue {
  const context = useContext(LeagueContext)
  if (!context) throw new Error('useLeague must be used inside LeagueProvider')
  return context
}
