export type Phase = 'league' | 'playoffs' | 'complete'
export type MatchPhase = 'league' | 'playoff'
export type MatchStatus = 'scheduled' | 'pending' | 'confirmed' | 'disputed' | 'voided'
export type MessageKind = 'chat' | 'result' | 'taunt'

/**
 * One row per person. user_id null means a placeholder: named as somebody's
 * teammate, waiting to be claimed at sign-up.
 */
export interface Player {
  id: string
  user_id: string | null
  email: string | null
  name: string
  team_id: string | null
  slot: 1 | 2 | null
  is_admin: boolean
  is_active: boolean
  created_at: string
}

export interface Team {
  id: string
  name: string
  is_active: boolean
  paid: boolean
  created_at: string
}

export interface Message {
  id: string
  kind: MessageKind
  author_id: string | null
  author_name: string | null
  team_name: string | null
  body: string | null
  match_id: string | null
  created_at: string
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
  /** Whoever signs in with this address gets the admin controls. */
  admin_email: string
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
  lost: number
  goals_for: number
  goals_against: number
  goal_difference: number
  points: number
  rank: number
}
