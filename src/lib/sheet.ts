import { useCallback, useEffect, useRef } from 'react'
import type { PointerEvent as ReactPointerEvent } from 'react'

/**
 * Apple's momentum projection: where a flick would come to rest, given its
 * release velocity. Not the textbook v²/2a — this is the exponential-decay
 * form scroll views actually use.
 */
function project(velocity: number, decelerationRate = 0.998): number {
  return (velocity / 1000) * decelerationRate / (1 - decelerationRate)
}

/** Progressive resistance past a boundary, so an edge never feels frozen. */
function rubberband(overshoot: number, dimension: number, constant = 0.55): number {
  return (overshoot * dimension * constant) / (dimension + constant * Math.abs(overshoot))
}

const DISMISS_DISTANCE = 96   // px of projected travel that commits to closing
const FLICK_VELOCITY = 420    // px/s downward that commits regardless of distance
/* Velocity is measured over the last moments of the gesture, not its whole
   length — a drag that creeps and then flicks should read as a flick. */
const VELOCITY_WINDOW = 90    // ms

/**
 * Drag-to-dismiss for a bottom sheet.
 *
 * Tracks the pointer 1:1, resists upward past the top edge, and on release
 * projects the throw forward to decide dismiss vs. settle — then hands the
 * release velocity to the settling spring so there is no seam between the
 * finger letting go and the animation taking over.
 *
 * `surface` goes on the sheet; `handle` goes on the grabber/header, so a drag
 * that starts inside a scrolling area scrolls it instead.
 */
export function useSheetDrag(onDismiss: () => void) {
  const el = useRef<HTMLDivElement | null>(null)
  const start = useRef(0)
  const history = useRef<Array<{ y: number; t: number }>>([])
  const dragging = useRef(false)

  const reducedMotion = typeof window !== 'undefined'
    && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches

  const setY = (y: number) => {
    const node = el.current
    if (!node) return
    node.style.transform = y === 0 ? '' : `translate3d(0, ${y}px, 0)`
  }

  const onPointerDown = useCallback((event: ReactPointerEvent<HTMLElement>) => {
    if (event.button !== 0 || reducedMotion) return
    const node = el.current
    if (!node) return
    dragging.current = true
    start.current = event.clientY
    history.current = []
    node.classList.add('sheet--dragging')
    node.classList.remove('sheet--settling')
    try { event.currentTarget.setPointerCapture(event.pointerId) } catch { /* no capture available */ }
  }, [reducedMotion])

  const onPointerMove = useCallback((event: ReactPointerEvent<HTMLElement>) => {
    if (!dragging.current) return
    const node = el.current
    if (!node) return

    const raw = event.clientY - start.current
    // Down follows the finger exactly; up resists more the further it goes.
    const y = raw >= 0 ? raw : -rubberband(-raw, node.offsetHeight || 400)
    setY(y)

    const now = performance.now()
    history.current.push({ y: event.clientY, t: now })
    if (history.current.length > 8) history.current.shift()
  }, [])

  const finish = useCallback((event: ReactPointerEvent<HTMLElement>) => {
    if (!dragging.current) return
    dragging.current = false
    const node = el.current
    if (!node) return
    try { event.currentTarget.releasePointerCapture(event.pointerId) } catch { /* already gone */ }

    // Only the tail of the gesture counts toward the throw.
    const now = performance.now()
    const recent = history.current.filter((s) => now - s.t <= VELOCITY_WINDOW)
    const sampled = recent.length >= 2 ? recent : history.current.slice(-2)
    const first = sampled[0]
    const last = sampled[sampled.length - 1]
    const dt = first && last ? last.t - first.t : 0
    const velocity = dt > 0 ? ((last.y - first.y) / dt) * 1000 : 0   // px/s

    const current = event.clientY - start.current
    const projected = current + project(velocity)

    node.classList.remove('sheet--dragging')
    node.classList.add('sheet--settling')

    if (projected > DISMISS_DISTANCE || velocity > FLICK_VELOCITY) {
      // Leave along the path it was thrown — down, the way it came in.
      setY((node.offsetHeight || 400) + 40)
      window.setTimeout(onDismiss, 180)
    } else {
      setY(0)
    }
  }, [onDismiss])

  // Clear the inline transform if the sheet is reused.
  useEffect(() => () => { dragging.current = false }, [])

  return {
    surface: { ref: el },
    handle: {
      onPointerDown,
      onPointerMove,
      onPointerUp: finish,
      onPointerCancel: finish,
      style: { touchAction: 'none' as const, cursor: 'grab' },
    },
  }
}
