import { useState } from 'react'
import { useAuth } from '../lib/auth'
import { useLeague } from '../lib/league'
import { cancelTeammateRequest } from '../lib/actions'
import { useToast } from './Toast'
import { PoolList } from './PoolList'
import { haptic, timeAgo } from '../lib/format'
import { readableError } from '../lib/supabase'

/**
 * The only way a team comes into existence: ask somebody in the pool, and they
 * accept. Nothing here can create a player — every name shown belongs to
 * somebody who signed themselves up.
 */
export function TeamFormation() {
  const { player } = useAuth()
  const league = useLeague()
  const toast = useToast()
  const [busy, setBusy] = useState<string | null>(null)

  if (!player) return null
  const { outgoingRequest } = league

  const act = async (key: string, run: () => Promise<unknown>, message: string) => {
    setBusy(key)
    try {
      await run()
      haptic([10, 30, 10])
      toast(message, 'good')
      await league.refresh()
      return true
    } catch (cause) {
      toast(readableError(cause), 'bad')
      return false
    } finally {
      setBusy(null)
    }
  }

  return (
    <>
      {outgoingRequest && (
        <section className="section">
          <div className="eyebrow">Your request</div>
          <div className="card spread">
            <div style={{ minWidth: 0 }}>
              <div className="t-headline row" style={{ gap: 'var(--s-2)' }}>
                <span className="pill pill--live" style={{ height: '1.375rem' }}>Waiting</span>
                <span className="truncate">
                  on {league.playerById(outgoingRequest.to_player)?.name ?? 'them'}
                </span>
              </div>
              <div className="t-caption dim">
                {outgoingRequest.proposed_team_name
                  ? `As “${outgoingRequest.proposed_team_name}” · ${timeAgo(outgoingRequest.created_at)}`
                  : `Sent ${timeAgo(outgoingRequest.created_at)}`}
              </div>
            </div>
            <button
              className="btn btn--ghost btn--sm"
              disabled={busy === outgoingRequest.id}
              onClick={() =>
                act(outgoingRequest.id, () => cancelTeammateRequest(outgoingRequest.id), 'Request cancelled.')
              }
            >
              Cancel
            </button>
          </div>
        </section>
      )}

      <section className="section">
        <div className="eyebrow">Player pool</div>
        <PoolList />
        <p className="t-caption dim" style={{ margin: 'var(--s-2) var(--s-1) 0' }}>
          Only people who have signed up appear here. Ask someone, and the team exists
          the moment they accept.
        </p>
      </section>
    </>
  )
}

