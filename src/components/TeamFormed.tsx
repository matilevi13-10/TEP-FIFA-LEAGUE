import { useEffect, useState } from 'react'
import { IconCheck } from './Icons'

/**
 * A brief, quiet celebration when a team forms. It announces itself to screen
 * readers, then gets out of the way on its own.
 */
export function TeamFormed({ teamName, onDone }: { teamName: string; onDone: () => void }) {
  const [leaving, setLeaving] = useState(false)

  useEffect(() => {
    const out = window.setTimeout(() => setLeaving(true), 1900)
    const done = window.setTimeout(onDone, 2300)
    return () => { window.clearTimeout(out); window.clearTimeout(done) }
  }, [onDone])

  return (
    <div className={`formed${leaving ? ' formed--leaving' : ''}`} role="status" aria-live="polite">
      <div className="formed__card">
        <span className="formed__tick" aria-hidden><IconCheck /></span>
        <div>
          <div className="eyebrow eyebrow--accent" style={{ margin: 0 }}>You're a team</div>
          <div className="t-title-2">{teamName}</div>
        </div>
      </div>
    </div>
  )
}
