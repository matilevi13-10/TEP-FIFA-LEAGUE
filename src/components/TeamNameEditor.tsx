import { useEffect, useRef, useState } from 'react'
import { useLeague } from '../lib/league'
import { leaveTeam, renameTeam } from '../lib/actions'
import { ConfirmButton } from './ConfirmButton'
import { useToast } from './Toast'
import { haptic } from '../lib/format'
import { readableError } from '../lib/supabase'
import type { Team } from '../lib/types'

/**
 * The team's name, editable in place by either teammate. Renaming is live
 * everywhere — the table, chat and bracket all read the same row.
 */
export function TeamNameEditor({ team }: { team: Team }) {
  const league = useLeague()
  const toast = useToast()
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(team.name)
  const [busy, setBusy] = useState(false)
  const input = useRef<HTMLInputElement>(null)

  useEffect(() => { if (!editing) setDraft(team.name) }, [team.name, editing])
  useEffect(() => { if (editing) input.current?.select() }, [editing])

  const save = async () => {
    const wanted = draft.trim()
    if (!wanted || wanted === team.name) { setEditing(false); setDraft(team.name); return }
    setBusy(true)
    try {
      await renameTeam(wanted)
      haptic([10, 30, 10])
      toast('Team renamed.', 'good')
      setEditing(false)
      await league.refresh()
    } catch (cause) {
      toast(readableError(cause), 'bad')
      input.current?.focus()
    } finally {
      setBusy(false)
    }
  }

  const leave = async () => {
    setBusy(true)
    try {
      await leaveTeam()
      haptic([20, 40, 20])
      toast(`${team.name} dissolved. You're both back in the pool.`, 'good')
      await league.refresh()
    } catch (cause) {
      toast(readableError(cause), 'bad')
    } finally {
      setBusy(false)
    }
  }

  if (!editing) {
    return (
      <div style={{ marginBottom: 'var(--s-2)' }}>
        <div className="spread">
          <div className="eyebrow" style={{ margin: 0 }}>{team.name}</div>
          <button
            className="btn btn--quiet btn--sm"
            style={{ padding: 0, minHeight: '1.75rem' }}
            onClick={() => { haptic(); setEditing(true) }}
          >
            Rename
          </button>
        </div>

        {/* Only while the season has not started. Once it has, team changes are
            the admin's call, so the option disappears rather than erroring. */}
        {!league.seasonStarted && (
          <div style={{ marginTop: 'var(--s-2)' }}>
            <ConfirmButton
              className="btn btn--plain btn--sm leave-team"
              style={{ padding: 0, minHeight: '1.75rem' }}
              disabled={busy}
              label="Leave team"
              confirmLabel={`This dissolves ${team.name} and returns both of you to the player pool — tap again`}
              onConfirm={leave}
            />
          </div>
        )}
      </div>
    )
  }

  return (
    <div className="row" style={{ gap: 'var(--s-2)', marginBottom: 'var(--s-3)' }}>
      <input
        ref={input} className="input" maxLength={40} autoFocus disabled={busy}
        aria-label="Team name"
        value={draft} onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter') void save()
          if (e.key === 'Escape') { setEditing(false); setDraft(team.name) }
        }}
      />
      <button className="btn btn--primary btn--sm" disabled={busy || !draft.trim()} onClick={save}>
        {busy ? 'Saving…' : 'Save'}
      </button>
      <button className="btn btn--ghost btn--sm" disabled={busy}
        onClick={() => { setEditing(false); setDraft(team.name) }}>
        Cancel
      </button>
    </div>
  )
}
