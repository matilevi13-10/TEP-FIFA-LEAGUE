import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { fixtureLabel, isFinalRound, needsShootout, tieLegs, useLeague } from '../lib/league'
import { submitLeagueResult, submitPlayoffResult } from '../lib/actions'
import { ScoreStepper } from './ScoreStepper'
import { useToast } from './Toast'
import { IconClose } from './Icons'
import { haptic } from '../lib/format'
import { readableError } from '../lib/supabase'
import { useSheetDrag } from '../lib/sheet'
import type { Match, Team } from '../lib/types'

/**
 * Score entry, opened from the Next Match card. This is the only way a result
 * gets in — the fixture decides the opponent, so there is nothing to pick.
 */
export function ScoreSheet({
  fixture, myTeam, onClose,
}: {
  fixture: Match
  myTeam: Team
  onClose: () => void
}) {
  const league = useLeague()
  const toast = useToast()
  const [mine, setMine] = useState(0)
  const [theirs, setTheirs] = useState(0)
  const [pens, setPens] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const drag = useSheetDrag(onClose)

  const mineFirst = fixture.team_a === myTeam.id
  const opponent = league.teamById(mineFirst ? fixture.team_b : fixture.team_a)
  const them = opponent?.name ?? 'They'

  // Penalties never touch the score, so any game can end level. When that
  // leaves the final or the aggregate level, whoever won the shootout goes
  // through, and it is recorded on its own.
  const playoff = fixture.phase === 'playoff'
  const final = playoff && isFinalRound(league.matches, fixture.round)
  const otherLeg = playoff && !final
    ? tieLegs(league.matches, fixture.round, fixture.slot).find((m) => m.leg !== fixture.leg)
    : undefined
  const earlier = otherLeg?.status === 'confirmed'
    ? {
        mine: (mineFirst ? otherLeg.score_a : otherLeg.score_b) ?? 0,
        theirs: (mineFirst ? otherLeg.score_b : otherLeg.score_a) ?? 0,
      }
    : undefined
  const aggMine = mine + (earlier?.mine ?? 0)
  const aggTheirs = theirs + (earlier?.theirs ?? 0)
  const shootout = needsShootout(
    fixture, league.matches, mineFirst ? mine : theirs, mineFirst ? theirs : mine,
  )
  const blocked = shootout && pens === null

  const send = async () => {
    setBusy(true)
    try {
      if (fixture.phase === 'playoff') {
        await submitPlayoffResult(fixture.id, mine, theirs, shootout ? pens : null)
      }
      else await submitLeagueResult(fixture.id, mine, theirs)
      haptic([10, 30, 10])
      toast(`Sent to ${opponent?.name ?? 'your opponent'} to confirm.`, 'good')
      onClose()
      await league.refresh()
    } catch (cause) {
      toast(readableError(cause), 'bad')
    } finally {
      setBusy(false)
    }
  }

  // Close on Escape and hold the page still underneath while the sheet is up.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', onKey)
    const overflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      window.removeEventListener('keydown', onKey)
      document.body.style.overflow = overflow
    }
  }, [onClose])

  const outcome = mine > theirs ? 'win' : mine < theirs ? 'loss' : 'draw'
  const verdict = outcome === 'win' ? 'Win' : outcome === 'loss' ? 'Loss' : playoff ? 'Level' : 'Draw'

  // Portalled to <body>: the page animates in with a transform, which would
  // otherwise make it the containing block for this fixed overlay and trap it
  // under the tab bar.
  return createPortal(
    <>
      <div className="scrim" onClick={onClose} />
      <div className="sheet score-sheet" role="dialog" aria-modal="true" aria-label="Submit score" {...drag.surface}>
        <div {...drag.handle}>
          <div className="sheet__grabber" aria-hidden />
          <div className="sheet__head">
            <div style={{ minWidth: 0 }}>
              <div className="t-caption dim">{fixtureLabel(fixture, league.matches)}</div>
              <div className="t-headline truncate">Submit score</div>
            </div>
            <button
              className="btn btn--ghost btn--sm btn--icon"
              aria-label="Close"
              onClick={onClose}
              style={{ width: '2.25rem' }}
            >
              <span className="btn__glyph"><IconClose /></span>
            </button>
          </div>
        </div>

        <div className="score-sheet__body">
          <div className="scoreboard">
            <ScoreStepper side="left" label={myTeam.name} sub="You" value={mine} onChange={setMine} accent />
            <div className="scoreboard__dash" aria-hidden>–</div>
            <ScoreStepper
              side="right" label={opponent?.name ?? 'Opponent'} sub="Them" value={theirs} onChange={setTheirs}
            />
          </div>

          {shootout ? (
            <div className="score-verdict score-verdict--pens">
              <div className="t-foot muted">
                {final ? `Level at ${mine}–${theirs}` : `Level at ${aggMine}–${aggTheirs} on aggregate`}
                {' '}— the score stays a tie. Who won on penalties?
              </div>
              <div className="segmented" role="radiogroup" aria-label="Penalty shootout winner">
                {[myTeam, opponent].map((team) => team && (
                  <button key={team.id} type="button" role="radio" aria-checked={pens === team.id}
                    className={`segmented__option${pens === team.id ? ' segmented__option--on' : ''}`}
                    onClick={() => { haptic(); setPens(team.id) }}>
                    <span className="truncate">{team.id === myTeam.id ? 'We did' : team.name}</span>
                  </button>
                ))}
              </div>
            </div>
          ) : (
            <div className={`score-verdict score-verdict--${outcome}`} aria-live="polite">
              <span className="score-verdict__tag">{verdict}</span>
              <span className="t-foot muted">
                {outcome === 'win'
                  ? `You win ${mine}–${theirs}.`
                  : outcome === 'loss'
                    ? `${them} win ${theirs}–${mine}.`
                    : `A ${mine}–${theirs} tie${playoff ? '' : ' — a point each'}.`}
                {earlier && ` ${aggMine > aggTheirs ? 'You go' : `${them} go`} through ${Math.max(aggMine, aggTheirs)}–${Math.min(aggMine, aggTheirs)} on aggregate.`}
              </span>
            </div>
          )}

          <button
            className="btn btn--primary btn--block"
            disabled={busy || blocked}
            onClick={send}
          >
            {busy ? 'Sending…' : blocked ? 'Pick the shootout winner' : `Submit ${mine}–${theirs}`}
          </button>
          <p className="t-caption dim center" style={{ margin: 'var(--s-3) 0 0' }}>
            Nothing moves the table until {opponent?.name ?? 'your opponent'} confirms.
          </p>
        </div>
      </div>
    </>,
    document.body,
  )
}
