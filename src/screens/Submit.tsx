import { useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../lib/auth'
import { useLeague } from '../lib/league'
import { submitLeagueResult, submitPlayoffResult } from '../lib/actions'
import { ScoreStepper } from '../components/ScoreStepper'
import { useToast } from '../components/Toast'
import { haptic, roundName } from '../lib/format'
import { readableError } from '../lib/supabase'

/**
 * Scores are entered against a fixture, never a freely chosen opponent — the
 * schedule already decided who you are playing.
 */
export function Submit() {
  const { player } = useAuth()
  const league = useLeague()
  const toast = useToast()
  const navigate = useNavigate()

  const [mine, setMine] = useState(0)
  const [theirs, setTheirs] = useState(0)
  const [busy, setBusy] = useState(false)

  const { settings, matches, myTeam, nextFixture } = league
  const isPlayoffs = settings?.phase === 'playoffs' || settings?.phase === 'complete'

  const playoffFixture = useMemo(() => {
    if (!myTeam || !isPlayoffs) return undefined
    return matches.find(
      (m) =>
        m.phase === 'playoff' &&
        (m.status === 'scheduled' || m.status === 'disputed') &&
        m.team_a !== null && m.team_b !== null &&
        (m.team_a === myTeam.id || m.team_b === myTeam.id),
    )
  }, [myTeam, matches, isPlayoffs])

  const fixture = isPlayoffs ? playoffFixture : nextFixture
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

  if (!fixture) {
    return (
      <div className="page">
        <Header title="Submit Result" sub={isPlayoffs ? 'Playoffs' : 'Nothing to play'} />
        <div className="card center" style={{ padding: 'var(--s-8) var(--s-4)' }}>
          <p className="muted t-subhead" style={{ margin: 0 }}>
            {isPlayoffs
              ? settings?.phase === 'complete'
                ? 'The season is finished.'
                : 'No open playoff game for you — either you are out, or your next opponent is still being decided.'
              : league.seasonStarted
                ? 'Every fixture on your schedule is played. Sit tight for the playoffs.'
                : "The season hasn't started, so there are no fixtures yet."}
          </p>
        </div>
      </div>
    )
  }

  const mineFirst = fixture.team_a === myTeam.id
  const opponent = league.teamById(mineFirst ? fixture.team_b : fixture.team_a)

  const level = mine === theirs
  const blocked = level

  const send = async () => {
    setBusy(true)
    try {
      if (isPlayoffs) await submitPlayoffResult(fixture.id, mine, theirs)
      else await submitLeagueResult(fixture.id, mine, theirs)
      haptic([10, 30, 10])
      toast(`Sent to ${opponent?.name ?? 'your opponent'} to confirm.`, 'good')
      await league.refresh()
      navigate('/')
    } catch (cause) {
      toast(readableError(cause), 'bad')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="page">
      <Header
        title="Submit Result"
        sub={
          isPlayoffs && fixture.round
            ? roundName(fixture.round, totalRounds)
            : `Round ${fixture.round ?? '—'}`
        }
      />

      <div className="card">
        <div className="row" style={{ alignItems: 'flex-start', gap: 'var(--s-4)' }}>
          <ScoreStepper label={myTeam.name} sub="You" value={mine} onChange={setMine} accent />
          <div className="dim" style={{ paddingTop: 90, fontSize: '1.25rem', fontWeight: 500 }}>–</div>
          <ScoreStepper
            label={opponent?.name ?? 'Opponent'} sub="Them" value={theirs} onChange={setTheirs}
          />
        </div>

        <div className="center" style={{ minHeight: '2.5rem', marginTop: 'var(--s-5)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
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
          disabled={busy || blocked}
          onClick={send}
          style={{ marginTop: 'var(--s-2)' }}
        >
          {busy ? 'Sending…' : 'Submit result'}
        </button>
      </div>

      <p className="t-caption dim center" style={{ margin: 'var(--s-3) var(--s-1) 0' }}>
        Nothing moves the table until {opponent?.name ?? 'your opponent'} confirms.
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
