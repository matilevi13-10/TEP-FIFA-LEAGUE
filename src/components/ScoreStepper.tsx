import { haptic } from '../lib/format'

interface Props {
  label: string
  sub?: string
  value: number
  onChange: (next: number) => void
  accent?: boolean
}

/**
 * Big thumb targets with the number itself typeable, so 1-0 is two taps and
 * 7-3 is still quick.
 */
export function ScoreStepper({ label, sub, value, onChange, accent }: Props) {
  const set = (next: number) => {
    const clamped = Math.max(0, Math.min(99, next))
    if (clamped !== value) haptic(8)
    onChange(clamped)
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 'var(--s-3)', flex: 1, minWidth: 0 }}>
      <div style={{ textAlign: 'center', minWidth: 0, width: '100%', minHeight: 40 }}>
        <div className="t-headline truncate" style={{ color: accent ? 'var(--accent)' : 'var(--text)' }}>
          {label}
        </div>
        {sub && <div className="t-caption dim" style={{ marginTop: '0.125rem' }}>{sub}</div>}
      </div>

      <input
        inputMode="numeric"
        pattern="[0-9]*"
        aria-label={`${label} score`}
        value={String(value)}
        onFocus={(event) => event.currentTarget.select()}
        onChange={(event) => {
          const digits = event.target.value.replace(/\D/g, '').slice(0, 2)
          onChange(digits === '' ? 0 : Math.min(99, Number(digits)))
        }}
        className="num"
        style={{
          width: '100%', maxWidth: '8.25rem', height: '6rem', textAlign: 'center',
          fontSize: '3.25rem', fontWeight: 700, lineHeight: 1, letterSpacing: '-0.035em',
          background: accent ? 'var(--accent-fill)' : 'var(--fill-1)',
          border: `1px solid ${accent ? 'var(--accent-line)' : 'var(--sep)'}`,
          borderRadius: 'var(--r-lg)', color: 'var(--text)',
        }}
      />

      <div className="row" style={{ gap: 'var(--s-2)' }}>
        <button type="button" className="btn btn--ghost" aria-label={`${label} minus one`}
          onClick={() => set(value - 1)}
          style={{ width: '3.5rem', minHeight: '3rem', padding: 0, fontSize: '1.375rem' }}>
          −
        </button>
        <button type="button" className="btn btn--ghost" aria-label={`${label} plus one`}
          onClick={() => set(value + 1)}
          style={{ width: '3.5rem', minHeight: '3rem', padding: 0, fontSize: '1.375rem' }}>
          +
        </button>
      </div>
    </div>
  )
}
