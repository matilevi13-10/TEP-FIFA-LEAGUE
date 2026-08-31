import { supabase } from './supabase'

/** Every write goes through a validated RPC — the client never touches a table. */
async function call<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args)
  if (error) throw error
  return data as T
}

// ── Account ───────────────────────────────────────────────────────────────
/** Attaches a username to the freshly created auth user. */
export const claimAccount = (username: string) =>
  call<string>('claim_account', { p_username: username })

// ── Teams ─────────────────────────────────────────────────────────────────
/** A team exists only once both sides agree, so this is the only entry point. */
export const sendTeammateRequest = (toPlayer: string, teamName: string | null) =>
  call<string>('send_teammate_request', { p_to_player: toPlayer, p_team_name: teamName })

export const cancelTeammateRequest = (requestId: string) =>
  call('cancel_teammate_request', { p_request_id: requestId })

export const declineTeammateRequest = (requestId: string) =>
  call('decline_teammate_request', { p_request_id: requestId })

export const acceptTeammateRequest = (requestId: string, teamName: string | null) =>
  call<string>('accept_teammate_request', { p_request_id: requestId, p_team_name: teamName })

/** Either teammate can rename their own team. */
export const renameTeam = (name: string) => call('rename_team', { p_name: name })

/** Dissolves the team and returns both players to the pool. Pre-season only. */
export const leaveTeam = () => call('leave_team')

// ── Matches ───────────────────────────────────────────────────────────────
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

// ── Chat ──────────────────────────────────────────────────────────────────
export const postMessage = (body: string) => call<string>('post_message', { p_body: body })
export const postTaunt = (matchId: string, body: string) =>
  call<string>('post_taunt', { p_match_id: matchId, p_body: body })

// ── Admin ─────────────────────────────────────────────────────────────────
export const adminRenamePlayer = (playerId: string, name: string) =>
  call('admin_rename_player', { p_player_id: playerId, p_name: name })

export const adminDeletePlayer = (playerId: string) =>
  call('admin_delete_player', { p_player_id: playerId })

export const adminCreateTeam = (name: string, playerA: string, playerB: string) =>
  call<string>('admin_create_team', { p_name: name, p_player_a: playerA, p_player_b: playerB })

export const adminUpdateTeam = (teamId: string, name: string, isActive: boolean, paid: boolean) =>
  call('admin_update_team', {
    p_team_id: teamId, p_name: name, p_is_active: isActive, p_paid: paid,
  })

export const adminDissolveTeam = (teamId: string) =>
  call('admin_dissolve_team', { p_team_id: teamId })

export const adminDeleteMessage = (messageId: string) =>
  call('admin_delete_message', { p_message_id: messageId })

export const adminUpdateSettings = (
  seasonName: string, gamesPerTeam: number, buyInCents: number,
  playoffSize: number | null, adminEmail: string | null = null,
) =>
  call('admin_update_settings', {
    p_season_name: seasonName, p_games_per_team: gamesPerTeam,
    p_buy_in_cents: buyInCents, p_playoff_size: playoffSize, p_admin_email: adminEmail,
  })

export const adminSetSeasonStarted = (started: boolean) =>
  call('admin_set_season_started', { p_started: started })

export const adminStartPlayoffs = (size: number) => call('admin_start_playoffs', { p_size: size })
export const adminResetPlayoffs = () => call('admin_reset_playoffs')

export const adminResolveMatch = (matchId: string, scoreA: number, scoreB: number, note?: string) =>
  call('admin_resolve_match', {
    p_match_id: matchId, p_score_a: scoreA, p_score_b: scoreB, p_note: note ?? null,
  })

export const adminVoidMatch = (matchId: string, note?: string) =>
  call('admin_void_match', { p_match_id: matchId, p_note: note ?? null })
