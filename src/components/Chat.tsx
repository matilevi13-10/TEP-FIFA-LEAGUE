import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { useAuth } from '../lib/auth'
import { useLeague } from '../lib/league'
import { postMessage } from '../lib/actions'
import { useToast } from './Toast'
import { IconChat, IconClose, IconSend } from './Icons'
import { haptic, timeAgo } from '../lib/format'
import { readableError } from '../lib/supabase'
import type { Message } from '../lib/types'

const READ_KEY = 'tep.chat.lastRead'

export function Chat() {
  const { player } = useAuth()
  const league = useLeague()
  const toast = useToast()
  const [open, setOpen] = useState(false)
  const [draft, setDraft] = useState('')
  const [sending, setSending] = useState(false)
  const [lastRead, setLastRead] = useState<string>(() => localStorage.getItem(READ_KEY) ?? '')
  const logRef = useRef<HTMLDivElement>(null)

  const { messages } = league
  const newest = messages.length ? messages[messages.length - 1].created_at : ''
  const unread = messages.filter((m) => m.created_at > lastRead && m.author_id !== player?.id).length

  const markRead = useCallback(() => {
    if (!newest) return
    localStorage.setItem(READ_KEY, newest)
    setLastRead(newest)
  }, [newest])

  // Stick to the bottom while the panel is open.
  useLayoutEffect(() => {
    if (!open || !logRef.current) return
    logRef.current.scrollTop = logRef.current.scrollHeight
  }, [open, messages.length])

  useEffect(() => { if (open) markRead() }, [open, newest, markRead])

  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open])

  if (!player) return null

  const send = async () => {
    const body = draft.trim()
    if (!body || sending) return
    setSending(true)
    try {
      await postMessage(body)
      setDraft('')
      haptic(10)
      await league.refresh()
    } catch (cause) {
      toast(readableError(cause), 'bad')
    } finally {
      setSending(false)
    }
  }

  return (
    <>
      <button
        className="chat-fab"
        aria-label={unread ? `League chat, ${unread} unread` : 'League chat'}
        onClick={() => { haptic(); setOpen(true) }}
      >
        <IconChat />
        {unread > 0 && <span className="chat-fab__dot">{unread > 99 ? '99+' : unread}</span>}
      </button>

      {open && (
        <>
          <div className="chat-scrim" onClick={() => setOpen(false)} />
          <div className="chat-panel" role="dialog" aria-label="League chat">
            <div className="chat-head">
              <div>
                <div style={{ fontSize: 15, fontWeight: 500 }}>League chat</div>
                <div style={{ fontSize: 12, color: 'var(--text-3)' }}>
                  Everyone in the league, one room
                </div>
              </div>
              <button
                className="btn btn--quiet btn--sm"
                aria-label="Close chat"
                onClick={() => setOpen(false)}
                style={{ minHeight: 40, width: 40, padding: 0 }}
              >
                <span style={{ width: 17, height: 17, display: 'block' }}><IconClose /></span>
              </button>
            </div>

            <div className="chat-log" ref={logRef}>
              {messages.length === 0 ? (
                <p className="center dim" style={{ fontSize: 14, margin: 'auto 0' }}>
                  Nothing here yet. Results show up automatically — say something in the meantime.
                </p>
              ) : (
                messages.map((message) => (
                  <Bubble key={message.id} message={message} mine={message.author_id === player.id} />
                ))
              )}
            </div>

            <div className="chat-foot">
              <input
                className="input"
                placeholder="Say something…"
                maxLength={500}
                value={draft}
                onChange={(e) => setDraft(e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); void send() } }}
              />
              <button
                className="btn btn--primary"
                aria-label="Send"
                disabled={sending || draft.trim().length === 0}
                onClick={send}
                style={{ width: 56, padding: 0, flexShrink: 0 }}
              >
                <span style={{ width: 20, height: 20, display: 'block' }}><IconSend /></span>
              </button>
            </div>
          </div>
        </>
      )}
    </>
  )
}

function Bubble({ message, mine }: { message: Message; mine: boolean }) {
  const league = useLeague()

  if (message.kind === 'result') {
    const match = league.matches.find((m) => m.id === message.match_id)
    const teamA = league.teamById(match?.team_a)
    const teamB = league.teamById(match?.team_b)
    const winner = message.team_name

    return (
      <div className="msg--result">
        <div className="eyebrow" style={{ margin: '0 0 5px' }}>
          {match?.phase === 'playoff' ? 'Playoff result' : 'Result'}
        </div>
        {match && teamA && teamB ? (
          <div className="msg__score">
            <span className={winner === teamA.name ? 'msg__won' : winner ? 'msg__lost' : ''}>{teamA.name}</span>
            {' '}<span style={{ color: 'var(--text-2)' }}>{match.score_a}–{match.score_b}</span>{' '}
            <span className={winner === teamB.name ? 'msg__won' : winner ? 'msg__lost' : ''}>{teamB.name}</span>
          </div>
        ) : (
          <div className="msg__score">{message.body}</div>
        )}
        <div style={{ fontSize: 11.5, color: 'var(--text-3)', marginTop: 4 }}>
          {winner ? `${winner} win` : 'Result'} · {timeAgo(message.created_at)}
        </div>
      </div>
    )
  }

  if (message.kind === 'taunt') {
    return (
      <div className="msg--taunt">
        <div className="msg__taunt-tag">Taunt</div>
        <div className="msg__body">“{message.body}”</div>
        <div style={{ fontSize: 11.5, color: 'var(--text-3)', marginTop: 6 }}>
          {message.team_name ?? message.author_name} · {timeAgo(message.created_at)}
        </div>
      </div>
    )
  }

  return (
    <div className={mine ? 'msg--mine' : undefined}>
      <div className="msg__meta">
        {mine ? 'You' : message.author_name}
        {message.team_name && <span className="dim"> · {message.team_name}</span>}
        <span className="dim"> · {timeAgo(message.created_at)}</span>
      </div>
      <div className="msg__body">{message.body}</div>
    </div>
  )
}
