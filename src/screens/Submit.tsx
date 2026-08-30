import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
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
  const { team } = useAuth()
  const league = useLeague()
  const toast = useToast()
  const navigate = useNavigate()

  const [opponent, setOpponent] = useState<Team | null>(null)
  const [mine, setMine] = useState(0)
  const [theirs, setTheirs] = useState(0)
  const [busy, setBusy] = useState(false)

  const { settings, matches, activeTeams } = league
  const isPlayoffs = settings?.phase === 'playoffs' || settings?.phase === 'complete'

  /** In the playoffs there is no choosing — you play the slot the bracket gives you. */
  const myBracketMatch = useMemo(() => {
    if (!team || !isPlayoffs) return null
    return (
      matches.find(
        (m) =>
          m.phase === 'playoff' &&
          (m.status === 'scheduled' || m.status === 'disputed') &&
          m.team_a !== null && m.team_b !== null &&
          (m.team_a === team.id || m.team_b === team.id),
      ) ?? null
    )
  }, [team, matches, isPlayoffs])

  const bracketOpponent = myBracketMatch
    ? league.teamById(myBracketMatch.team_a === team?.id ? myBracketMatch.team_b : myBracketMatch.team_a)
    : undefined

  const totalRounds = settings?.playoff_size ? Math.log2(settings.playoff_size) : 0

  if (!team) return null

  const used = slotsUsed(matches, team.id)
  const remaining = Math.max(0, (settings?.games_per_team ?? 0) - used)

  const drawn = mine === theirs
  const lost = mine < theirs
  const blocked = lost || (isPlayoffs && drawn)
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
        <div className="card center" style={{ padding: 30 }}>
          <p className="muted" style={{ margin: 0, fontSize: 14 }}>
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
    const opponents = activeTeams.filter((t) => t.id !== team.id)
    return (
      <div className="page">
        <Header
          title="Submit Result"
          sub={remaining > 0 ? `${remaining} of your ${settings?.games_per_team ?? 0} games left` : 'All your games are played'}
        />

        {remaining === 0 ? (
          <div className="card center" style={{ padding: 30 }}>
            <p className="muted" style={{ margin: 0, fontSize: 14 }}>
              You have played all {settings?.games_per_team} of your games. Sit tight for the playoffs.
            </p>
          </div>
        ) : (
          <>
            <div className="eyebrow">Who did you play?</div>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10 }}>
              {opponents.map((other) => {
                const theirRemaining = (settings?.games_per_team ?? 0) - slotsUsed(matches, other.id)
                const full = theirRemaining <= 0
                return (
                  <button
                    key={other.id}
                    className="card"
                    disabled={full}
                    onClick={() => { haptic(); setOpponent(other) }}
                    style={{
                      textAlign: 'left', padding: '15px 14px', minHeight: 78,
                      opacity: full ? 0.4 : 1, cursor: full ? 'not-allowed' : 'pointer',
                    }}
                  >
                    <div style={{ fontSize: 15, fontWeight: 500, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                      {other.name}
                    </div>
                    <div style={{ fontSize: 11.5, color: 'var(--text-3)', marginTop: 2 }}>
                      {full ? 'Games all played' : `${other.player_one} & ${other.player_two}`}
                    </div>
                  </button>
                )
              })}
            </div>
            {opponents.length === 0 && (
              <div className="card center muted" style={{ padding: 30 }}>
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
            style={{ padding: 0, marginBottom: 12, color: 'var(--text-3)' }}
          >
            <span style={{ width: 14, height: 14, display: 'block', transform: 'rotate(180deg)' }}>
              <IconChevron />
            </span>
            Change opponent
          </button>
        )}

        <div className="row" style={{ alignItems: 'flex-start', gap: 14 }}>
          <ScoreStepper label={team.name} sub="You" value={mine} onChange={setMine} accent />
          {/* 40px label block + 12px gap + half of the 96px input = the score row's axis */}
          <div style={{ paddingTop: 90, fontSize: 20, color: 'var(--text-3)', fontWeight: 500 }}>–</div>
          <ScoreStepper
            label={activeOpponent?.name ?? 'Opponent'}
            sub="Them"
            value={theirs}
            onChange={setTheirs}
          />
        </div>

        <div className="center" style={{ minHeight: 40, marginTop: 18, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          {lost ? (
            <span style={{ fontSize: 13, color: 'var(--danger)' }}>
              The winning team submits — ask {activeOpponent?.name ?? 'them'} to send this one.
            </span>
          ) : isPlayoffs && drawn ? (
            <span style={{ fontSize: 13, color: 'var(--danger)' }}>
              Playoff games can't end level. Play it out.
            </span>
          ) : (
            <span style={{ fontSize: 13, color: 'var(--text-2)' }}>
              {drawn
                ? `Draw ${mine}–${theirs}. Either team can send a draw.`
                : `You win ${mine}–${theirs}. ${activeOpponent?.name ?? 'They'} confirms it.`}
            </span>
          )}
        </div>

        <button
          className="btn btn--primary btn--block"
          disabled={busy || blocked}
          onClick={send}
          style={{ marginTop: 6 }}
        >
          {busy ? 'Sending…' : 'Submit result'}
        </button>
      </div>

      <p style={{ fontSize: 12, color: 'var(--text-3)', margin: '12px 2px 0', textAlign: 'center' }}>
        Nothing moves the table until {activeOpponent?.name ?? 'your opponent'} confirms.
      </p>
    </div>
  )
}

function Header({ title, sub }: { title: string; sub: string }) {
  return (
    <div className="section" style={{ marginBottom: 16 }}>
      <h1 style={{ fontSize: 26, fontWeight: 500, letterSpacing: '-0.02em', margin: 0 }}>{title}</h1>
      <div style={{ fontSize: 13, color: 'var(--text-3)' }}>{sub}</div>
    </div>
  )
}
