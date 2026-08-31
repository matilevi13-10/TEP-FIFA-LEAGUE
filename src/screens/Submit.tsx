import { useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../lib/auth'
import { slotsUsed, useLeague } from '../lib/league'
import { submitLeagueResult, submitPlayoffResult } from '../lib/actions'
import { ScoreStepper } from '../components/ScoreStepper'
import { useToast } from '../components/Toast'
import { IconChevron } from '../components/Icons'
import { haptic, roundName } from '../lib/format'
import { readableError } from '../lib/supabase'
import type { Team } from '../lib/types'

export function Submit() {
  const { player } = useAuth()
  const league = useLeague()
  const toast = useToast()
  const navigate = useNavigate()

  const [opponent, setOpponent] = useState<Team | null>(null)
  const [mine, setMine] = useState(0)
  const [theirs, setTheirs] = useState(0)
  const [busy, setBusy] = useState(false)

  const { settings, matches, activeTeams, myTeam } = league
  const isPlayoffs = settings?.phase === 'playoffs' || settings?.phase === 'complete'

  /** In the playoffs there is no choosing — you play the slot the bracket gives you. */
  const myBracketMatch = useMemo(() => {
    if (!myTeam || !isPlayoffs) return null
    return (
      matches.find(
        (m) =>
          m.phase === 'playoff' &&
          (m.status === 'scheduled' || m.status === 'disputed') &&
          m.team_a !== null && m.team_b !== null &&
          (m.team_a === myTeam.id || m.team_b === myTeam.id),
      ) ?? null
    )
  }, [myTeam, matches, isPlayoffs])

  const bracketOpponent = myBracketMatch
    ? league.teamById(myBracketMatch.team_a === myTeam?.id ? myBracketMatch.team_b : myBracketMatch.team_a)
    : undefined

  const totalRounds = settings?.playoff_size ? Math.log2(settings.playoff_size) : 0

  if (!player) return null
  if (!myTeam) {
    return (
      <div className="page">
        <Header title="Submit Result" sub="You need a team first" />
        <div className="card center" style={{ padding: 'var(--s-8) var(--s-4)' }}>
          <p className="muted t-subhead" style={{ margin: '0 0 var(--s-4)' }}>
            Results are logged by teams. Pair up with someone from the player pool first.
          </p>
          <Link to="/teams" className="btn btn--primary">Find a teammate</Link>
        </div>
      </div>
    )
  }

  const used = slotsUsed(matches, myTeam.id)
  const remaining = Math.max(0, (settings?.games_per_team ?? 0) - used)

  const level = mine === theirs
  const lost = mine < theirs
  // Every game has a winner, so a level score is never submittable.
  const blocked = lost || level
  const activeOpponent = isPlayoffs ? bracketOpponent : opponent

  const reset = () => { setOpponent(null); setMine(0); setTheirs(0) }

  const send = async () => {
    setBusy(true)
    try {
      if (isPlayoffs) {
        if (!myBracketMatch) return
        await submitPlayoffResult(myBracketMatch.id, mine, theirs)
      } else {
        if (!opponent) return
        await submitLeagueResult(opponent.id, mine, theirs)
      }
      haptic([10, 30, 10])
      toast(`Sent to ${activeOpponent?.name ?? 'your opponent'} to confirm.`, 'good')
      reset()
      await league.refresh()
      navigate('/')
    } catch (cause) {
      toast(readableError(cause), 'bad')
    } finally {
      setBusy(false)
    }
  }

  // ── Playoffs with nothing to play ───────────────────────────────────────
  if (isPlayoffs && !myBracketMatch) {
    return (
      <div className="page">
        <Header title="Submit Result" sub="Playoffs" />
        <div className="card center" style={{ padding: 'var(--s-8) var(--s-4)' }}>
          <p className="muted t-subhead" style={{ margin: 0 }}>
            {settings?.phase === 'complete'
              ? 'The season is finished.'
              : 'No open playoff game for you right now — either you are out, or your next opponent is still being decided.'}
          </p>
        </div>
      </div>
    )
  }

  // ── League: pick an opponent ────────────────────────────────────────────
  if (!isPlayoffs && !opponent) {
    const opponents = activeTeams.filter((t) => t.id !== myTeam.id)
    return (
      <div className="page">
        <Header
          title="Submit Result"
          sub={remaining > 0 ? `${remaining} of your ${settings?.games_per_team ?? 0} games left` : 'All your games are played'}
        />

        {remaining === 0 ? (
          <div className="card center" style={{ padding: 'var(--s-8) var(--s-4)' }}>
            <p className="muted t-subhead" style={{ margin: 0 }}>
              You have played all {settings?.games_per_team} of your games. Sit tight for the playoffs.
            </p>
          </div>
        ) : (
          <>
            <div className="eyebrow">Who did you play?</div>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 'var(--s-3)' }}>
              {opponents.map((other) => {
                const theirRemaining = (settings?.games_per_team ?? 0) - slotsUsed(matches, other.id)
                const full = theirRemaining <= 0
                const names = league.playersFor(other.id).join(' & ')
                return (
                  <button
                    key={other.id}
                    className="card card--tap"
                    disabled={full}
                    onClick={() => { haptic(); setOpponent(other) }}
                    style={{ minHeight: '4.75rem', opacity: full ? 0.4 : 1, cursor: full ? 'not-allowed' : 'pointer' }}
                  >
                    <div className="t-headline truncate">{other.name}</div>
                    <div className="t-caption dim" style={{ marginTop: '0.125rem' }}>
                      {full ? 'Games all played' : names}
                    </div>
                  </button>
                )
              })}
            </div>
            {opponents.length === 0 && (
              <div className="card center muted t-subhead" style={{ padding: 'var(--s-8) var(--s-4)' }}>
                No other teams in the league yet.
              </div>
            )}
          </>
        )}
      </div>
    )
  }

  // ── Score entry ─────────────────────────────────────────────────────────
  return (
    <div className="page">
      <Header
        title="Submit Result"
        sub={
          isPlayoffs && myBracketMatch?.round
            ? roundName(myBracketMatch.round, totalRounds)
            : 'League game'
        }
      />

      <div className="card">
        {!isPlayoffs && (
          <button
            className="btn btn--quiet btn--sm"
            onClick={reset}
            style={{ padding: 0, marginBottom: 'var(--s-3)' }}
          >
            <span className="btn__glyph" style={{ width: '0.875rem', height: '0.875rem', transform: 'rotate(180deg)' }}>
              <IconChevron />
            </span>
            Change opponent
          </button>
        )}

        <div className="row" style={{ alignItems: 'flex-start', gap: 'var(--s-4)' }}>
          <ScoreStepper label={myTeam.name} sub="You" value={mine} onChange={setMine} accent />
          {/* 40px label block + 12px gap + half of the 96px input = the score row's axis */}
          <div className="dim" style={{ paddingTop: 90, fontSize: '1.25rem', fontWeight: 500 }}>–</div>
          <ScoreStepper
            label={activeOpponent?.name ?? 'Opponent'}
            sub="Them"
            value={theirs}
            onChange={setTheirs}
          />
        </div>

        <div className="center" style={{ minHeight: '2.5rem', marginTop: 'var(--s-5)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          {level ? (
            <span className="t-foot" style={{ color: 'var(--danger)' }} role="alert">
              Games can't end level — play it out until somebody wins.
            </span>
          ) : lost ? (
            <span className="t-foot" style={{ color: 'var(--danger)' }} role="alert">
              The winning team submits — ask {activeOpponent?.name ?? 'them'} to send this one.
            </span>
          ) : (
            <span className="t-foot muted">
              You win {mine}–{theirs}. {activeOpponent?.name ?? 'They'} confirms it.
            </span>
          )}
        </div>

        <button
          className="btn btn--primary btn--block"
          disabled={busy || blocked}
          onClick={send}
          style={{ marginTop: 'var(--s-2)' }}
        >
          {busy ? 'Sending…' : 'Submit result'}
        </button>
      </div>

      <p className="t-caption dim center" style={{ margin: 'var(--s-3) var(--s-1) 0' }}>
        Nothing moves the table until {activeOpponent?.name ?? 'your opponent'} confirms.
      </p>
    </div>
  )
}

function Header({ title, sub }: { title: string; sub: string }) {
  return (
    <div className="section" style={{ marginBottom: 'var(--s-5)' }}>
      <h1 className="t-title" style={{ margin: 0 }}>{title}</h1>
      <div className="t-foot dim">{sub}</div>
    </div>
  )
}
