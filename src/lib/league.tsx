import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { supabase } from './supabase'
import { useAuth } from './auth'
import type { Match, Message, Player, Settings, Standing, Team } from './types'

interface LeagueValue {
  loading: boolean
  teams: Team[]
  players: Player[]
  matches: Match[]
  messages: Message[]
  settings: Settings | null
  standings: Standing[]
  activeTeams: Team[]
  /** Everybody without a team, including unclaimed placeholders. */
  pool: Player[]
  /** Teamless people who have actually signed up — pickable as a teammate. */
  availableTeammates: Player[]
  teamById: (id: string | null | undefined) => Team | undefined
  playerById: (id: string | null | undefined) => Player | undefined
  /** The two player names for a team, in slot order. */
  playersFor: (teamId: string | null | undefined) => string[]
  myTeam: Team | undefined
  /** Results submitted against my team that we still have to approve. */
  pendingForMe: Match[]
  /** Results we submitted that the other team has not approved yet. */
  awaitingOthers: Match[]
  potCents: number
  refresh: () => Promise<void>
}

const LeagueContext = createContext<LeagueValue | null>(null)

/**
 * Mirrors the `standings` view in schema.sql: confirmed league games only,
 * ordered by points, then goal difference, then goals scored, then name.
 * Computed here too so the table reacts the instant realtime fires.
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

/** League slots a team has used: confirmed, pending and disputed all count. */
export function slotsUsed(matches: Match[], teamId: string): number {
  return matches.filter(
    (m) =>
      m.phase === 'league' &&
      (m.status === 'confirmed' || m.status === 'pending' || m.status === 'disputed') &&
      (m.team_a === teamId || m.team_b === teamId),
  ).length
}

export function LeagueProvider({ children }: { children: ReactNode }) {
  const { session, player } = useAuth()
  const [teams, setTeams] = useState<Team[]>([])
  const [players, setPlayers] = useState<Player[]>([])
  const [matches, setMatches] = useState<Match[]>([])
  const [messages, setMessages] = useState<Message[]>([])
  const [settings, setSettings] = useState<Settings | null>(null)
  const [loading, setLoading] = useState(true)
  const pending = useRef<number | null>(null)

  const refresh = useCallback(async () => {
    if (!session) return
    const [t, p, m, msg, s] = await Promise.all([
      supabase.from('teams').select('*').order('name'),
      supabase.from('players').select('*').order('name'),
      supabase.from('matches').select('*').order('created_at', { ascending: false }),
      supabase.from('messages').select('*').order('created_at', { ascending: true }).limit(300),
      supabase.from('league_settings').select('*').eq('id', 1).maybeSingle(),
    ])
    if (t.data) setTeams(t.data as Team[])
    if (p.data) setPlayers(p.data as Player[])
    if (m.data) setMatches(m.data as Match[])
    if (msg.data) setMessages(msg.data as Message[])
    if (s.data) setSettings(s.data as Settings)
    setLoading(false)
  }, [session])

  useEffect(() => {
    if (!session) {
      setTeams([]); setPlayers([]); setMatches([]); setMessages([])
      setSettings(null); setLoading(true)
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
    for (const table of ['matches', 'teams', 'players', 'messages', 'league_settings']) {
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
      loading, teams, players, matches, messages, settings, activeTeams,
      pool: players.filter((p) => p.team_id === null && p.is_active),
      availableTeammates: players.filter(
        (p) => p.team_id === null && p.is_active && p.user_id !== null && p.id !== me,
      ),
      standings: computeStandings(teams, matches),
      teamById: (id) => (id ? teamsById.get(id) : undefined),
      playerById: (id) => (id ? playersById.get(id) : undefined),
      playersFor: (id) => (id ? (namesByTeam.get(id) ?? []) : []),
      myTeam: myTeamId ? teamsById.get(myTeamId) : undefined,
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
      refresh,
    }
  }, [loading, teams, players, matches, messages, settings, player, refresh])

  return <LeagueContext.Provider value={value}>{children}</LeagueContext.Provider>
}

export function useLeague(): LeagueValue {
  const context = useContext(LeagueContext)
  if (!context) throw new Error('useLeague must be used inside LeagueProvider')
  return context
}
