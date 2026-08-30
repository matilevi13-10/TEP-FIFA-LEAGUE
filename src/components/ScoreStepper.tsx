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
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 12, flex: 1, minWidth: 0 }}>
      <div style={{ textAlign: 'center', minWidth: 0, width: '100%', minHeight: 40 }}>
        <div
          style={{
            fontSize: 15, fontWeight: 500,
            color: accent ? 'var(--accent)' : 'var(--text)',
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          }}
        >
          {label}
        </div>
        {sub && <div style={{ fontSize: 12, color: 'var(--text-3)', marginTop: 2 }}>{sub}</div>}
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
        style={{
          width: '100%', maxWidth: 132, height: 96, textAlign: 'center',
          fontSize: 52, fontWeight: 700, lineHeight: 1, letterSpacing: '-0.03em',
          background: accent ? 'rgba(181,168,255,0.10)' : 'rgba(255,255,255,0.05)',
          border: `1px solid ${accent ? 'rgba(181,168,255,0.34)' : 'var(--line)'}`,
          borderRadius: 18, color: 'var(--text)', outline: 'none',
        }}
      />

      <div className="row" style={{ gap: 8 }}>
        <button type="button" className="btn btn--ghost" aria-label={`${label} minus one`}
          onClick={() => set(value - 1)}
          style={{ width: 56, minHeight: 48, padding: 0, fontSize: 22, fontWeight: 500 }}>
          −
        </button>
        <button type="button" className="btn btn--ghost" aria-label={`${label} plus one`}
          onClick={() => set(value + 1)}
          style={{ width: 56, minHeight: 48, padding: 0, fontSize: 22, fontWeight: 500 }}>
          +
        </button>
      </div>
    </div>
  )
}
