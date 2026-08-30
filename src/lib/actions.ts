import { supabase } from './supabase'

/** Every write goes through a validated RPC — the client never touches a table. */
async function call<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args)
  if (error) throw error
  return data as T
}

export const submitLeagueResult = (opponentId: string, myScore: number, opponentScore: number) =>
  call<string>('submit_league_result', {
    p_opponent: opponentId, p_my_score: myScore, p_opp_score: opponentScore,
  })

export const submitPlayoffResult = (matchId: string, myScore: number, opponentScore: number) =>
  call<string>('submit_playoff_result', {
    p_match_id: matchId, p_my_score: myScore, p_opp_score: opponentScore,
  })

export const confirmMatch = (matchId: string) => call('confirm_match', { p_match_id: matchId })
export const disputeMatch = (matchId: string) => call('dispute_match', { p_match_id: matchId })
export const cancelSubmission = (matchId: string) => call('cancel_submission', { p_match_id: matchId })

export const adminCreateTeam = (name: string, playerOne: string, playerTwo: string, pin: string) =>
  call<string>('admin_create_team', {
    p_name: name, p_player_one: playerOne, p_player_two: playerTwo, p_pin: pin,
  })

export const adminUpdateTeam = (
  teamId: string, name: string, playerOne: string, playerTwo: string, isActive: boolean, paid: boolean,
) =>
  call('admin_update_team', {
    p_team_id: teamId, p_name: name, p_player_one: playerOne,
    p_player_two: playerTwo, p_is_active: isActive, p_paid: paid,
  })

export const adminSetPin = (teamId: string, pin: string) =>
  call('admin_set_pin', { p_team_id: teamId, p_pin: pin })

export const adminSetRole = (teamId: string, isAdmin: boolean) =>
  call('admin_set_role', { p_team_id: teamId, p_is_admin: isAdmin })

export const adminDeleteTeam = (teamId: string) => call('admin_delete_team', { p_team_id: teamId })

export const adminUpdateSettings = (
  seasonName: string, gamesPerTeam: number, buyInCents: number, playoffSize: number | null,
) =>
  call('admin_update_settings', {
    p_season_name: seasonName, p_games_per_team: gamesPerTeam,
    p_buy_in_cents: buyInCents, p_playoff_size: playoffSize,
  })

export const adminStartPlayoffs = (size: number) => call('admin_start_playoffs', { p_size: size })
export const adminResetPlayoffs = () => call('admin_reset_playoffs')

export const adminResolveMatch = (matchId: string, scoreA: number, scoreB: number, note?: string) =>
  call('admin_resolve_match', {
    p_match_id: matchId, p_score_a: scoreA, p_score_b: scoreB, p_note: note ?? null,
  })

export const adminVoidMatch = (matchId: string, note?: string) =>
  call('admin_void_match', { p_match_id: matchId, p_note: note ?? null })
