import { useState } from 'react'
import { useLeague } from '../lib/league'
import { createTeam } from '../lib/actions'
import { useToast } from './Toast'
import { haptic } from '../lib/format'
import { readableError } from '../lib/supabase'

/**
 * Team creation is one-sided on purpose: you name the team and say who you're
 * playing with. If they haven't signed up yet, the name becomes a placeholder
 * they claim by registering under it.
 */
export function AddTeamForm() {
  const league = useLeague()
  const toast = useToast()
  const [name, setName] = useState('')
  const [teammateId, setTeammateId] = useState('')
  const [teammateName, setTeammateName] = useState('')
  const [busy, setBusy] = useState(false)

  const available = league.availableTeammates
  const picked = teammateId !== ''
  const ready = name.trim().length > 0 && (picked || teammateName.trim().length > 0)

  const create = async () => {
    if (!ready || busy) return
    setBusy(true)
    try {
      await createTeam(name.trim(), picked ? teammateId : null, picked ? null : teammateName.trim())
      haptic([10, 40, 10])
      toast('Team created.', 'good')
      setName(''); setTeammateId(''); setTeammateName('')
      await league.refresh()
    } catch (cause) {
      toast(readableError(cause), 'bad')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="card card--accent stack">
      <div>
        <div className="t-headline">You're not on a team yet</div>
        <p className="t-subhead muted" style={{ margin: 'var(--s-1) 0 0' }}>
          Teams are two players. Create yours to start logging results.
        </p>
      </div>

      <div className="field">
        <label className="field__label" htmlFor="team-name">Team name</label>
        <input
          id="team-name" className="input" maxLength={40} placeholder="Give your team a name"
          value={name} onChange={(e) => setName(e.target.value)}
        />
      </div>

      <div className="field">
        <label className="field__label" htmlFor="teammate">Teammate</label>
        {available.length > 0 && (
          <select
            id="teammate" className="input" value={teammateId}
            onChange={(e) => { setTeammateId(e.target.value); if (e.target.value) setTeammateName('') }}
          >
            <option value="">Choose a signed-up player…</option>
            {available.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
        )}
        {!picked && (
          <input
            className="input" maxLength={40}
            placeholder={available.length > 0 ? '…or type their name' : "Your teammate's name"}
            value={teammateName} onChange={(e) => setTeammateName(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') void create() }}
            style={{ marginTop: available.length > 0 ? 'var(--s-2)' : 0 }}
          />
        )}
        <p className="field__hint">
          {picked
            ? 'They join the team straight away.'
            : "They'll join automatically when they sign up with that exact username."}
        </p>
      </div>

      <button className="btn btn--primary btn--block" disabled={!ready || busy} onClick={create}>
        {busy ? 'Creating…' : 'Create team'}
      </button>
    </div>
  )
}
