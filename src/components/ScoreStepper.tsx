import { haptic } from '../lib/format'

interface Props {
  label: string
  sub?: string
  value: number
  onChange: (next: number) => void
  accent?: boolean
  /** Which column of the scoreboard grid this side sits in. */
  side: 'left' | 'right'
}

/**
 * One side of the scoreboard. Big thumb targets with the number itself
 * typeable, so 1-0 is two taps and 7-3 is still quick.
 *
 * Renders with `display: contents` so its name, number and buttons land on
 * the scoreboard's shared rows — both numbers always line up with the dash
 * between them, however long either team name is.
 */
export function ScoreStepper({ label, sub, value, onChange, accent, side }: Props) {
  const set = (next: number) => {
    const clamped = Math.max(0, Math.min(99, next))
    if (clamped !== value) haptic(8)
    onChange(clamped)
  }

  return (
    <div className={`stepper stepper--${side}${accent ? ' stepper--accent' : ''}`}>
      <div className="stepper__label">
        <div className="stepper__name truncate">{label}</div>
        {sub && <div className="stepper__sub">{sub}</div>}
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
        className="stepper__value num"
      />

      <div className="stepper__buttons">
        <button type="button" className="stepper__btn" aria-label={`${label} minus one`}
          disabled={value === 0} onClick={() => set(value - 1)}>
          −
        </button>
        <button type="button" className="stepper__btn" aria-label={`${label} plus one`}
          onClick={() => set(value + 1)}>
          +
        </button>
      </div>
    </div>
  )
}
