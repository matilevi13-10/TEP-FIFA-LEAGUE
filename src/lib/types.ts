export type Phase = 'league' | 'playoffs' | 'complete'
export type MatchPhase = 'league' | 'playoff'
export type MatchStatus = 'scheduled' | 'pending' | 'confirmed' | 'disputed' | 'voided'

export interface Player {
  id: string
  team_id: string
  name: string
  slot: 1 | 2
}

export interface Team {
  id: string
  user_id: string | null
  name: string
  is_admin: boolean
  is_active: boolean
  paid: boolean
  created_at: string
}

/** The reduced shape the sign-in picker gets before anyone is authenticated. */
export interface TeamOption {
  id: string
  name: string
  player_one: string
  player_two: string
  is_active: boolean
}

export interface Match {
  id: string
  phase: MatchPhase
  round: number | null
  slot: number | null
  team_a: string | null
  team_b: string | null
  seed_a: number | null
  seed_b: number | null
  score_a: number | null
  score_b: number | null
  winner_id: string | null
  status: MatchStatus
  submitted_by: string | null
  confirmed_by: string | null
  admin_note: string | null
  created_at: string
  confirmed_at: string | null
  updated_at: string
}

export interface Settings {
  id: number
  season_name: string
  games_per_team: number
  buy_in_cents: number
  playoff_size: number | null
  phase: Phase
  champion_team_id: string | null
  playoffs_started_at: string | null
  updated_at: string
}

export interface Standing {
  team_id: string
  name: string
  played: number
  won: number
  drawn: number
  lost: number
  goals_for: number
  goals_against: number
  goal_difference: number
  points: number
  rank: number
}
