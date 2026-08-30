import { useEffect, useRef, useState } from 'react'
import { haptic } from '../lib/format'

interface Props {
  label: string
  confirmLabel: string
  onConfirm: () => void
  className?: string
  disabled?: boolean
  style?: React.CSSProperties
}

/**
 * Two taps instead of a modal: the button asks for itself, and forgets after
 * four seconds. Keeps destructive admin actions from being one stray thumb.
 */
export function ConfirmButton({ label, confirmLabel, onConfirm, className, disabled, style }: Props) {
  const [armed, setArmed] = useState(false)
  const timer = useRef<number | null>(null)

  useEffect(() => () => { if (timer.current) window.clearTimeout(timer.current) }, [])

  return (
    <button
      type="button"
      className={className}
      disabled={disabled}
      style={style}
      onClick={() => {
        haptic(armed ? [10, 30, 10] : 12)
        if (armed) {
          if (timer.current) window.clearTimeout(timer.current)
          setArmed(false)
          onConfirm()
        } else {
          setArmed(true)
          timer.current = window.setTimeout(() => setArmed(false), 4000)
        }
      }}
    >
      {armed ? confirmLabel : label}
    </button>
  )
}
