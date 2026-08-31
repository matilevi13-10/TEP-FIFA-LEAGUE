import { useState } from 'react'
import { useAuth } from '../lib/auth'
import { useLeague } from '../lib/league'
import {
  acceptTeammateRequest, cancelTeammateRequest, declineTeammateRequest, sendTeammateRequest,
} from '../lib/actions'
import { useToast } from './Toast'
import { haptic } from '../lib/format'
import { readableError } from '../lib/supabase'

/**
 * The player pool, with whatever action is actually available on each row.
 *
 * This is the single rendering of the pool — the Teams page and the home page
 * both use it, so a row cannot end up actionable in one place and inert in the
 * other, which is exactly what happened before.
 */
export function PoolList() {
  const { player } = useAuth()
  const league = useLeague()
  const toast = useToast()
  const [busy, setBusy] = useState<string | null>(null)
  const [asking, setAsking] = useState<string | null>(null)
  const [proposed, setProposed] = useState('')
  const [accepting, setAccepting] = useState<string | null>(null)
  const [teamName, setTeamName] = useState('')

  if (!player) return null
  const { pool, incomingRequests, outgoingRequest } = league

  // Actions only make sense if I could actually join a team.
  const canAct = player.team_id === null && player.is_active

  const run = async (key: string, work: () => Promise<unknown>, message: string) => {
    setBusy(key)
    try {
      await work()
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

  if (pool.length === 0) {
    return (
      <div className="card center muted t-subhead" style={{ padding: 'var(--s-7) var(--s-4)' }}>
        Everyone has a team.
      </div>
    )
  }

  return (
    <div className="stack">
      {pool.map((other) => {
        const isMe = other.id === player.id
        const theirRequest = incomingRequests.find((r) => r.from_player === other.id)
        const iAsked = outgoingRequest?.to_player === other.id

        return (
          <div key={other.id} className="card">
            <div className="pool-row">
              <div className="pool-row__name">
                <div className="t-headline truncate">{other.name}</div>
                <div className="t-caption dim">
                  {isMe ? 'Waiting for a teammate'
                    : theirRequest ? 'Wants to team up with you'
                    : iAsked ? 'You asked them'
                    : 'Looking for a teammate'}
                </div>
              </div>

              <div className="pool-row__action">
                {isMe ? (
                  <span className="pill">You</span>
                ) : !canAct ? null
                  : theirRequest ? (
                    <>
                      <button
                        className="btn btn--primary btn--sm btn--pill"
                        disabled={busy !== null}
                        onClick={() => {
                          haptic()
                          setAccepting(theirRequest.id)
                          setTeamName(theirRequest.proposed_team_name ?? '')
                          setAsking(null)
                        }}
                      >
                        Accept
                      </button>
                      <button
                        className="btn btn--ghost btn--sm btn--pill"
                        disabled={busy !== null}
                        onClick={() =>
                          run(theirRequest.id, () => declineTeammateRequest(theirRequest.id), 'Declined.')
                        }
                      >
                        Decline
                      </button>
                    </>
                  ) : iAsked && outgoingRequest ? (
                    <button
                      className="btn btn--ghost btn--sm btn--pill"
                      disabled={busy !== null}
                      onClick={() =>
                        run(outgoingRequest.id, () => cancelTeammateRequest(outgoingRequest.id),
                          'Request cancelled.')
                      }
                    >
                      Requested · Cancel
                    </button>
                  ) : (
                    <button
                      className="btn btn--primary btn--sm btn--pill"
                      disabled={Boolean(outgoingRequest) || busy !== null}
                      title={outgoingRequest ? 'Cancel your open request first' : undefined}
                      onClick={() => {
                        haptic()
                        setAsking(other.id)
                        setProposed('')
                        setAccepting(null)
                      }}
                    >
                      Request
                    </button>
                  )}
              </div>
            </div>

            {/* Optional name to propose with the request. */}
            {asking === other.id && (
              <Expand
                label="Team name (optional)"
                placeholder="They can change it when they accept"
                value={proposed}
                onChange={setProposed}
                confirmLabel="Send request"
                busy={busy === `send-${other.id}`}
                onConfirm={async () => {
                  const ok = await run(
                    `send-${other.id}`,
                    () => sendTeammateRequest(other.id, proposed.trim() || null),
                    `Request sent to ${other.name}.`,
                  )
                  if (ok) { setAsking(null); setProposed('') }
                }}
                onCancel={() => setAsking(null)}
              />
            )}

            {/* Accepting needs a name for the team it creates. */}
            {theirRequest && accepting === theirRequest.id && (
              <Expand
                label="Your team name"
                placeholder="Name your team"
                value={teamName}
                onChange={setTeamName}
                confirmLabel="Form the team"
                confirmDisabled={teamName.trim().length === 0}
                busy={busy === theirRequest.id}
                onConfirm={async () => {
                  const ok = await run(
                    theirRequest.id,
                    () => acceptTeammateRequest(theirRequest.id, teamName.trim() || null),
                    "You're a team.",
                  )
                  if (ok) { setAccepting(null); setTeamName('') }
                }}
                onCancel={() => setAccepting(null)}
              />
            )}
          </div>
        )
      })}
    </div>
  )
}

function Expand({
  label, placeholder, value, onChange, confirmLabel, confirmDisabled, busy, onConfirm, onCancel,
}: {
  label: string
  placeholder: string
  value: string
  onChange: (v: string) => void
  confirmLabel: string
  confirmDisabled?: boolean
  busy: boolean
  onConfirm: () => void
  onCancel: () => void
}) {
  return (
    <div className="stack" style={{ marginTop: 'var(--s-4)' }}>
      <div className="field">
        <span className="field__label">{label}</span>
        <input
          className="input" autoFocus maxLength={40} placeholder={placeholder}
          value={value} onChange={(e) => onChange(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !confirmDisabled) onConfirm()
            if (e.key === 'Escape') onCancel()
          }}
        />
      </div>
      <div className="row" style={{ gap: 'var(--s-2)' }}>
        <button className="btn btn--primary" style={{ flex: 1 }}
          disabled={busy || confirmDisabled} onClick={onConfirm}>
          {busy ? 'Working…' : confirmLabel}
        </button>
        <button className="btn btn--ghost" disabled={busy} onClick={onCancel}>Cancel</button>
      </div>
    </div>
  )
}
