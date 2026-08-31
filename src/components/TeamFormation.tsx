import { useState } from 'react'
import { useAuth } from '../lib/auth'
import { useLeague } from '../lib/league'
import {
  acceptTeammateRequest, cancelTeammateRequest, declineTeammateRequest, sendTeammateRequest,
} from '../lib/actions'
import { useToast } from './Toast'
import { IconCheck, IconClose } from './Icons'
import { haptic, timeAgo } from '../lib/format'
import { readableError } from '../lib/supabase'
import type { Player, TeamRequest } from '../lib/types'

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
  const [asking, setAsking] = useState<Player | null>(null)
  const [proposed, setProposed] = useState('')

  if (!player) return null
  const { availableTeammates, incomingRequests, outgoingRequest } = league

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

  const send = async () => {
    if (!asking) return
    const ok = await act(
      `send-${asking.id}`,
      () => sendTeammateRequest(asking.id, proposed.trim() || null),
      `Request sent to ${asking.name}.`,
    )
    if (ok) { setAsking(null); setProposed('') }
  }

  return (
    <>
      {/* Anything waiting on me comes first, in accent. */}
      {incomingRequests.length > 0 && (
        <section className="section">
          <div className="eyebrow eyebrow--accent">
            {incomingRequests.length === 1
              ? 'Someone wants to team up'
              : `${incomingRequests.length} teammate requests`}
          </div>
          <div className="stack">
            {incomingRequests.map((request) => (
              <IncomingCard
                key={request.id}
                request={request}
                busy={busy === request.id}
                onAccept={(name) =>
                  act(request.id, () => acceptTeammateRequest(request.id, name || null), "You're a team.")
                }
                onDecline={() => act(request.id, () => declineTeammateRequest(request.id), 'Declined.')}
              />
            ))}
          </div>
        </section>
      )}

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
        {availableTeammates.length === 0 ? (
          <div className="card center muted t-subhead" style={{ padding: 'var(--s-7) var(--s-4)' }}>
            Nobody else is looking for a teammate right now.
          </div>
        ) : (
          <div className="stack">
            {availableTeammates.map((other) => {
              const asked = outgoingRequest?.to_player === other.id
              const asksMe = incomingRequests.some((r) => r.from_player === other.id)
              return (
                <div key={other.id} className="card">
                  <div className="spread">
                    <div style={{ minWidth: 0 }}>
                      <div className="t-headline">{other.name}</div>
                      <div className="t-caption dim">
                        {asksMe ? 'Asked to team up with you'
                          : asked ? 'Request sent'
                          : 'Looking for a teammate'}
                      </div>
                    </div>
                    {!asked && !asksMe && (
                      <button
                        className="btn btn--ghost btn--sm"
                        disabled={Boolean(outgoingRequest) || busy !== null}
                        onClick={() => { haptic(); setAsking(other); setProposed('') }}
                        title={outgoingRequest ? 'Cancel your open request first' : undefined}
                      >
                        Request
                      </button>
                    )}
                  </div>

                  {asking?.id === other.id && (
                    <div className="stack" style={{ marginTop: 'var(--s-4)' }}>
                      <div className="field">
                        <label className="field__label" htmlFor={`tn-${other.id}`}>
                          Team name (optional)
                        </label>
                        <input
                          id={`tn-${other.id}`} className="input" autoFocus maxLength={40}
                          placeholder="They can change it when they accept"
                          value={proposed} onChange={(e) => setProposed(e.target.value)}
                          onKeyDown={(e) => { if (e.key === 'Enter') void send() }}
                        />
                      </div>
                      <div className="row" style={{ gap: 'var(--s-2)' }}>
                        <button className="btn btn--primary" style={{ flex: 1 }}
                          disabled={busy === `send-${other.id}`} onClick={send}>
                          Send request
                        </button>
                        <button className="btn btn--ghost" onClick={() => setAsking(null)}>Cancel</button>
                      </div>
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        )}
        <p className="t-caption dim" style={{ margin: 'var(--s-2) var(--s-1) 0' }}>
          Only people who have signed up appear here. Ask someone, and the team exists
          the moment they accept.
        </p>
      </section>
    </>
  )
}

function IncomingCard({
  request, busy, onAccept, onDecline,
}: {
  request: TeamRequest
  busy: boolean
  onAccept: (name: string) => void
  onDecline: () => void
}) {
  const league = useLeague()
  const from = league.playerById(request.from_player)
  const [name, setName] = useState(request.proposed_team_name ?? '')

  return (
    <div className="card card--accent">
      <div style={{ marginBottom: 'var(--s-4)' }}>
        <div className="t-title-2">{from?.name ?? 'Someone'} wants to team up</div>
        <div className="t-caption dim">
          {timeAgo(request.created_at)}
          {request.proposed_team_name && ` · suggested “${request.proposed_team_name}”`}
        </div>
      </div>

      <div className="field" style={{ marginBottom: 'var(--s-3)' }}>
        <label className="field__label" htmlFor={`accept-${request.id}`}>Your team name</label>
        <input
          id={`accept-${request.id}`} className="input" maxLength={40}
          placeholder="Name your team" value={name} onChange={(e) => setName(e.target.value)}
        />
      </div>

      <button
        className="btn btn--primary btn--block"
        disabled={busy || name.trim().length === 0}
        onClick={() => onAccept(name.trim())}
      >
        <span className="btn__glyph"><IconCheck /></span>
        {busy ? 'Forming team…' : 'Accept — form the team'}
      </button>
      <button className="btn btn--plain btn--block" disabled={busy} onClick={onDecline}
        style={{ marginTop: 'var(--s-1)' }}>
        <span className="btn__glyph" style={{ width: '0.9375rem', height: '0.9375rem' }}><IconClose /></span>
        Decline
      </button>
    </div>
  )
}
