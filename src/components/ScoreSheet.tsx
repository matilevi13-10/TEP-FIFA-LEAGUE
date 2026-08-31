import { useState } from 'react'
import { useLeague } from '../lib/league'
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
  const [busy, setBusy] = useState(false)
  const drag = useSheetDrag(onClose)

  const mineFirst = fixture.team_a === myTeam.id
  const opponent = league.teamById(mineFirst ? fixture.team_b : fixture.team_a)
  const level = mine === theirs

  const send = async () => {
    setBusy(true)
    try {
      if (fixture.phase === 'playoff') await submitPlayoffResult(fixture.id, mine, theirs)
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

  return (
    <>
      <div className="scrim" onClick={onClose} />
      <div className="sheet score-sheet" role="dialog" aria-label="Submit score" {...drag.surface}>
        <div {...drag.handle}>
          <div className="sheet__grabber" aria-hidden />
          <div className="sheet__head">
            <div style={{ minWidth: 0 }}>
              <div className="t-headline truncate">vs {opponent?.name ?? 'Opponent'}</div>
              <div className="t-caption dim">
                {fixture.phase === 'playoff' ? 'Playoff' : `Round ${fixture.round}`}
              </div>
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
          <div className="row" style={{ alignItems: 'flex-start', gap: 'var(--s-4)' }}>
            <ScoreStepper label={myTeam.name} sub="You" value={mine} onChange={setMine} accent />
            <div className="dim" style={{ paddingTop: 90, fontSize: '1.25rem', fontWeight: 500 }}>–</div>
            <ScoreStepper
              label={opponent?.name ?? 'Opponent'} sub="Them" value={theirs} onChange={setTheirs}
            />
          </div>

          <div
            className="center"
            style={{ minHeight: '2.5rem', marginTop: 'var(--s-4)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}
          >
            {level ? (
              <span className="t-foot" style={{ color: 'var(--danger)' }} role="alert">
                Games can't end level — play it out until somebody wins.
              </span>
            ) : (
              <span className="t-foot muted">
                {mine > theirs
                  ? `You win ${mine}–${theirs}. ${opponent?.name ?? 'They'} confirms it.`
                  : `${opponent?.name ?? 'They'} win ${theirs}–${mine}. They confirm it.`}
              </span>
            )}
          </div>

          <button
            className="btn btn--primary btn--block"
            disabled={busy || level}
            onClick={send}
          >
            {busy ? 'Sending…' : 'Submit result'}
          </button>
          <p className="t-caption dim center" style={{ margin: 'var(--s-3) 0 0' }}>
            Nothing moves the table until {opponent?.name ?? 'your opponent'} confirms.
          </p>
        </div>
      </div>
    </>
  )
}
