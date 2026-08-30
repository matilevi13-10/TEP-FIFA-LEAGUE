import mark from '../assets/tep-mark.png'
import markLavender from '../assets/tep-mark-lavender.png'

/** The TEP mark. Height drives the size; the aspect ratio is fixed at ~2.93:1. */
export function Logo({ height = 22, tone = 'white' }: { height?: number; tone?: 'white' | 'lavender' }) {
  return (
    <img
      src={tone === 'lavender' ? markLavender : mark}
      alt="TEP"
      height={height}
      style={{ height, width: 'auto', display: 'block' }}
      draggable={false}
    />
  )
}
