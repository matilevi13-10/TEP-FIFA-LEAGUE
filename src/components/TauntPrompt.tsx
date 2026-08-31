import { useEffect, useMemo, useState } from 'react'
import { useAuth } from '../lib/auth'
import { useLeague } from '../lib/league'
import { postTaunt } from '../lib/actions'
import { useToast } from './Toast'
import { haptic } from '../lib/format'
import { useSheetDrag } from '../lib/sheet'
import { readableError } from '../lib/supabase'

const DISMISSED_KEY = 'tep.taunt.dismissed'
/**
 * Wins older than this never raise the prompt. A taunt is an in-the-moment
 * thing, and a short window stops a queue of popups piling up if somebody
 * opens the app days later.
 */
const WINDOW_MS = 2 * 60 * 60 * 1000

function readDismissed(): string[] {
  try {
    return JSON.parse(localStorage.getItem(DISMISSED_KEY) ?? '[]') as string[]
  } catch {
    return []
  }
}

/**
 * Watches for a win of ours being confirmed and offers the mic drop. One per
 * match, winner only — both also enforced in the database.
 */
export function TauntPrompt() {
  const { player } = useAuth()
  const league = useLeague()
  const toast = useToast()
  const [dismissed, setDismissed] = useState<string[]>(readDismissed)
  const [body, setBody] = useState('')
  const [busy, setBusy] = useState(false)
  const drag = useSheetDrag(() => close())

  const myTeamId = league.myTeam?.id

  const match = useMemo(() => {
    if (!myTeamId) return undefined
    const taunted = new Set(
      league.messages.filter((m) => m.kind === 'taunt').map((m) => m.match_id),
    )
    return league.matches.find(
      (m) =>
        m.status === 'confirmed' &&
        m.winner_id === myTeamId &&
        m.confirmed_by === (m.team_a === myTeamId ? m.team_b : m.team_a) &&
        !taunted.has(m.id) &&
        !dismissed.includes(m.id) &&
        m.confirmed_at !== null &&
        Date.now() - new Date(m.confirmed_at).getTime() < WINDOW_MS,
    )
  }, [league.matches, league.messages, myTeamId, dismissed])

  useEffect(() => { if (match) haptic([15, 60, 15]) }, [match?.id])

  if (!player || !match) return null

  const opponent = league.teamById(match.team_a === myTeamId ? match.team_b : match.team_a)
  const mineFirst = match.team_a === myTeamId
  const myScore = (mineFirst ? match.score_a : match.score_b) ?? 0
  const theirScore = (mineFirst ? match.score_b : match.score_a) ?? 0

  const close = () => {
    const next = [...dismissed, match.id].slice(-50)
    localStorage.setItem(DISMISSED_KEY, JSON.stringify(next))
    setDismissed(next)
    setBody('')
  }

  const send = async () => {
    const text = body.trim()
    if (!text) return
    setBusy(true)
    try {
      await postTaunt(match.id, text)
      haptic([10, 40, 10, 40, 20])
      toast('Taunt posted to the league chat.', 'good')
      close()
      await league.refresh()
    } catch (cause) {
      toast(readableError(cause), 'bad')
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <div className="scrim" style={{ zIndex: 69 }} onClick={close} />
      <div className="taunt-sheet" role="dialog" aria-label="Taunt your opponent" {...drag.surface}>
        <div {...drag.handle}>
          <div className="sheet__grabber" aria-hidden />
        </div>
        <div className="taunt-title" style={{ marginTop: 'var(--s-3)' }}>TAUNT</div>

        <p className="center t-subhead muted" style={{ margin: 'var(--s-4) 0 var(--s-1)' }}>
          You beat <strong style={{ color: 'var(--text)', fontWeight: 600 }}>{opponent?.name ?? 'them'}</strong>{' '}
          <span style={{ color: 'var(--text)', fontWeight: 700 }}>{myScore}–{theirScore}</span>
          {match.phase === 'playoff' && ' in the playoffs'}.
        </p>
        <p className="center dim t-foot" style={{ margin: '0 0 var(--s-5)' }}>
          Say something to the whole league. One shot.
        </p>

        <input
          className="input"
          autoFocus
          maxLength={280}
          placeholder="Make it count…"
          value={body}
          onChange={(e) => setBody(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') void send() }}
          style={{ marginBottom: 'var(--s-3)' }}
        />

        <button
          className="btn btn--primary btn--block"
          disabled={busy || body.trim().length === 0}
          onClick={send}
        >
          {busy ? 'Dropping…' : 'Send it'}
        </button>
        <button className="btn btn--plain btn--block" disabled={busy} onClick={close} style={{ marginTop: 'var(--s-1)' }}>
          Stay humble
        </button>
      </div>
    </>
  )
}
