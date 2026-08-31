import { useEffect, useRef, useState } from 'react'
import { useLeague } from '../lib/league'
import { renameTeam } from '../lib/actions'
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

  if (!editing) {
    return (
      <div className="spread" style={{ marginBottom: 'var(--s-2)' }}>
        <div className="eyebrow" style={{ margin: 0 }}>{team.name}</div>
        <button
          className="btn btn--quiet btn--sm"
          style={{ padding: 0, minHeight: '1.75rem' }}
          onClick={() => { haptic(); setEditing(true) }}
        >
          Rename
        </button>
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
