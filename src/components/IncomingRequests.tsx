import { useEffect, useRef, useState } from 'react'
import { useLeague } from '../lib/league'
import { acceptTeammateRequest, declineTeammateRequest } from '../lib/actions'
import { useToast } from './Toast'
import { IconCheck, IconClose } from './Icons'
import { haptic, timeAgo } from '../lib/format'
import { readableError } from '../lib/supabase'
import type { TeamRequest } from '../lib/types'

/**
 * The league's handshake, at the top of home. Everything happens on the card —
 * accept forms the team and the page transitions underneath; decline slides it
 * away without ceremony.
 */
export function IncomingRequests({ onAccepted }: { onAccepted: (teamName: string) => void }) {
  const league = useLeague()
  const toast = useToast()
  const [busy, setBusy] = useState<string | null>(null)
  const [leaving, setLeaving] = useState<Set<string>>(new Set())

  // Newest first — the most recent ask is the one you're deciding about.
  const requests = [...league.incomingRequests].sort(
    (a, b) => b.created_at.localeCompare(a.created_at),
  )
  if (requests.length === 0) return null

  const dismiss = (id: string) => setLeaving((prev) => new Set(prev).add(id))

  const accept = async (request: TeamRequest, name: string) => {
    setBusy(request.id)
    try {
      await acceptTeammateRequest(request.id, name || null)
      haptic([12, 40, 12, 40, 24])
      dismiss(request.id)
      // Let the card finish leaving before the page rebuilds under it.
      window.setTimeout(async () => { await league.refresh(); onAccepted(name) }, 200)
    } catch (cause) {
      toast(readableError(cause), 'bad')
      setBusy(null)
    }
  }

  const decline = async (request: TeamRequest) => {
    setBusy(request.id)
    try {
      await declineTeammateRequest(request.id)
      haptic(10)
      dismiss(request.id)
      window.setTimeout(() => void league.refresh(), 200)
    } catch (cause) {
      toast(readableError(cause), 'bad')
      setBusy(null)
    }
  }

  return (
    <section className="section" style={{ marginTop: 0 }}>
      <div className="eyebrow eyebrow--accent">
        {requests.length === 1 ? 'Teammate request' : `${requests.length} teammate requests`}
      </div>
      <div className="stack">
        {requests.map((request) => (
          <RequestCard
            key={request.id}
            request={request}
            busy={busy === request.id}
            leaving={leaving.has(request.id)}
            onAccept={(name) => accept(request, name)}
            onDecline={() => decline(request)}
          />
        ))}
      </div>
    </section>
  )
}

function RequestCard({
  request, busy, leaving, onAccept, onDecline,
}: {
  request: TeamRequest
  busy: boolean
  leaving: boolean
  onAccept: (name: string) => void
  onDecline: () => void
}) {
  const league = useLeague()
  const from = league.playerById(request.from_player)
  const [name, setName] = useState(request.proposed_team_name ?? '')
  const card = useRef<HTMLDivElement>(null)

  // Pulse once on arrival so a request landing while you're looking registers,
  // then never again — a thing that keeps pulsing is an alarm.
  useEffect(() => {
    const node = card.current
    if (!node) return
    node.classList.add('request--arriving')
    const timer = window.setTimeout(() => node.classList.remove('request--arriving'), 1400)
    return () => window.clearTimeout(timer)
  }, [])

  return (
    <div ref={card} className={`card card--accent request${leaving ? ' request--leaving' : ''}`}>
      <div className="spread" style={{ marginBottom: 'var(--s-4)' }}>
        <div style={{ minWidth: 0 }}>
          <div className="t-title-2">{from?.name ?? 'Someone'} wants to team up</div>
          <div className="t-caption dim">{timeAgo(request.created_at)}</div>
        </div>
        <span className="pill pill--accent" style={{ flexShrink: 0 }}>New</span>
      </div>

      {request.proposed_team_name && (
        <div className="request__proposal">
          <span className="t-caption dim">Suggested name</span>
          <span className="t-headline">{request.proposed_team_name}</span>
        </div>
      )}

      <div className="field" style={{ marginBottom: 'var(--s-4)' }}>
        <label className="field__label" htmlFor={`rq-${request.id}`}>
          {request.proposed_team_name ? 'Team name — change it if you like' : 'Name your team'}
        </label>
        <input
          id={`rq-${request.id}`} className="input" maxLength={40}
          placeholder="Name your team" value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && name.trim()) onAccept(name.trim()) }}
        />
      </div>

      <div className="row" style={{ gap: 'var(--s-2)' }}>
        <button
          className="btn btn--primary"
          style={{ flex: 2 }}
          disabled={busy || name.trim().length === 0}
          onClick={() => onAccept(name.trim())}
        >
          <span className="btn__glyph"><IconCheck /></span>
          {busy ? 'Forming…' : 'Accept'}
        </button>
        <button className="btn btn--ghost" style={{ flex: 1 }} disabled={busy} onClick={onDecline}>
          <span className="btn__glyph" style={{ width: '0.9375rem', height: '0.9375rem' }}>
            <IconClose />
          </span>
          Decline
        </button>
      </div>
    </div>
  )
}
