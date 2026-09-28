export type Phase = 'league' | 'playoffs' | 'complete'
export type MatchPhase = 'league' | 'playoff'
/** 'bye' is a first-round playoff slot with nobody to play — team_a goes through. */
export type MatchStatus = 'scheduled' | 'pending' | 'confirmed' | 'disputed' | 'voided' | 'bye'
export type MessageKind = 'chat' | 'result' | 'taunt'
export type RequestStatus = 'pending' | 'accepted' | 'declined' | 'cancelled' | 'expired'

/** One row per person, created only when that person signs themselves up. */
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

export interface TeamRequest {
  id: string
  from_player: string
  to_player: string
  proposed_team_name: string | null
  status: RequestStatus
  created_at: string
  responded_at: string | null
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
  /** League: the week. Playoffs: the bracket round. */
  round: number | null
  slot: number | null
  /** Game 1 or 2 of the week's pairing, or leg 1 or 2 of a playoff tie. A final has only leg 1. */
  leg: 1 | 2
  team_a: string | null
  team_b: string | null
  /** Picks their team and the console. */
  home_team: string | null
  seed_a: number | null
  seed_b: number | null
  score_a: number | null
  score_b: number | null
  /** Null on a draw. */
  winner_id: string | null
  /**
   * Penalties never touch the score. When a level final or a level aggregate
   * goes to a shootout, this is who won it.
   */
  shootout_winner: string | null
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
  /** Always even — two games per opponent, so 12 games is 6 rounds. */
  games_per_team: number
  buy_in_cents: number
  /** Whoever signs in with this address gets the admin controls. */
  admin_email: string
  /** Null until the admin opens the season. */
  season_started_at: string | null
  /** Everyone qualifies, so this is the number of teams seeded. */
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
