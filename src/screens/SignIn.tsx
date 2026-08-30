import { useCallback, useEffect, useState } from 'react'
import { Logo } from '../components/Logo'
import { IconBackspace, IconChevron, IconSpinner } from '../components/Icons'
import { fetchTeamOptions, useAuth } from '../lib/auth'
import { isConfigured, readableError } from '../lib/supabase'
import { haptic } from '../lib/format'
import type { TeamOption } from '../lib/types'

const KEYS = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0', 'del']

export function SignIn() {
  const { signIn } = useAuth()
  const [teams, setTeams] = useState<TeamOption[] | null>(null)
  const [chosen, setChosen] = useState<TeamOption | null>(null)
  const [pin, setPin] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const loadTeams = useCallback(() => {
    if (!isConfigured) return
    setError(null)
    fetchTeamOptions()
      .then(setTeams)
      .catch((cause) => setError(readableError(cause)))
  }, [])

  useEffect(loadTeams, [loadTeams])

  // Fires the moment the fourth digit lands — no submit button to hunt for.
  useEffect(() => {
    if (pin.length !== 4 || !chosen || busy) return
    setBusy(true)
    setError(null)
    signIn(chosen.id, pin)
      .then(() => haptic([10, 40, 10]))
      .catch((cause) => {
        setError(readableError(cause))
        setPin('')
        haptic([40, 30, 40])
      })
      .finally(() => setBusy(false))
  }, [pin, chosen, busy, signIn])

  if (!isConfigured) {
    return (
      <Shell>
        <div className="card" style={{ textAlign: 'left' }}>
          <div className="eyebrow">Setup needed</div>
          <p style={{ margin: '0 0 10px' }}>
            This build has no Supabase credentials. Locally, put them in <code>.env</code> and restart.
            On Amplify, set them under App settings &rarr; Environment variables, then redeploy.
          </p>
          <pre style={{
            margin: 0, padding: 12, borderRadius: 12, background: 'rgba(0,0,0,0.45)',
            border: '1px solid var(--line)', fontSize: 12, overflowX: 'auto', color: 'var(--text-2)',
          }}>
{`VITE_SUPABASE_URL=https://xxx.supabase.co
VITE_SUPABASE_ANON_KEY=eyJ...`}
          </pre>
        </div>
      </Shell>
    )
  }

  if (!chosen) {
    return (
      <Shell>
        {teams === null && error ? (
          <div className="card" style={{ textAlign: 'left' }}>
            <div className="eyebrow">Can't reach the league</div>
            <p style={{ margin: '0 0 14px' }}>{error}</p>
            <button className="btn btn--ghost btn--block" onClick={loadTeams}>Try again</button>
          </div>
        ) : teams === null ? (
          <div className="stack">
            {[0, 1, 2, 3].map((i) => <div key={i} className="skeleton" style={{ height: 62 }} />)}
          </div>
        ) : (
          <div className="stack">
            <div className="eyebrow" style={{ textAlign: 'center', marginBottom: 2 }}>Who are you?</div>
            {teams.map((team) => (
              <button
                key={team.id}
                className="card"
                onClick={() => { haptic(); setChosen(team); setError(null) }}
                style={{
                  display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                  gap: 12, textAlign: 'left', width: '100%', minHeight: 62, padding: '14px 16px',
                }}
              >
                <span style={{ minWidth: 0 }}>
                  <span style={{ display: 'block', fontSize: 16, fontWeight: 500 }}>{team.name}</span>
                  <span style={{ display: 'block', fontSize: 13, color: 'var(--text-3)' }}>
                    {team.player_one} &amp; {team.player_two}
                  </span>
                </span>
                <span style={{ width: 18, height: 18, color: 'var(--text-3)', flexShrink: 0 }}>
                  <IconChevron />
                </span>
              </button>
            ))}
            {teams.length === 0 && (
              <p className="center dim" style={{ fontSize: 14 }}>
                No teams yet. Sign in as the admin account to create them.
              </p>
            )}
          </div>
        )}
        {error && teams !== null && (
          <p className="center" style={{ color: 'var(--danger)', fontSize: 14 }}>{error}</p>
        )}
      </Shell>
    )
  }

  return (
    <Shell>
      <div className="center" style={{ marginBottom: 4 }}>
        <div style={{ fontSize: 19, fontWeight: 500 }}>{chosen.name}</div>
        <div style={{ fontSize: 13, color: 'var(--text-3)' }}>
          {chosen.player_one} &amp; {chosen.player_two}
        </div>
      </div>

      <div className="row" style={{ justifyContent: 'center', gap: 14, height: 26 }}>
        {[0, 1, 2, 3].map((index) => (
          <span
            key={index}
            style={{
              width: 13, height: 13, borderRadius: '50%',
              background: index < pin.length ? 'var(--accent)' : 'transparent',
              border: `1.5px solid ${index < pin.length ? 'var(--accent)' : 'var(--line-hi)'}`,
              boxShadow: index < pin.length ? '0 0 12px var(--glow)' : 'none',
              transition: 'all 160ms var(--ease)',
            }}
          />
        ))}
      </div>

      <div style={{ minHeight: 22, textAlign: 'center' }}>
        {busy && <span className="dim" style={{ fontSize: 13 }}>Signing you in…</span>}
        {!busy && error && <span style={{ color: 'var(--danger)', fontSize: 13 }}>{error}</span>}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 10, maxWidth: 300, margin: '0 auto', width: '100%' }}>
        {KEYS.map((key, index) =>
          key === '' ? (
            <span key={index} />
          ) : (
            <button
              key={index}
              className="btn btn--ghost"
              disabled={busy}
              onClick={() => {
                haptic()
                setError(null)
                setPin((current) => (key === 'del' ? current.slice(0, -1) : (current + key).slice(0, 4)))
              }}
              aria-label={key === 'del' ? 'Delete' : key}
              style={{ minHeight: 62, fontSize: 23, fontWeight: 500 }}
            >
              {key === 'del' ? <span style={{ width: 21, height: 21, display: 'block' }}><IconBackspace /></span> : key}
            </button>
          ),
        )}
      </div>

      <button
        className="btn btn--quiet"
        onClick={() => { setChosen(null); setPin(''); setError(null) }}
        style={{ margin: '0 auto' }}
      >
        {busy ? <span style={{ width: 16, height: 16 }}><IconSpinner /></span> : 'Not your team?'}
      </button>
    </Shell>
  )
}

function Shell({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        minHeight: '100dvh', display: 'flex', flexDirection: 'column',
        alignItems: 'center', justifyContent: 'center', gap: 22,
        padding: 'calc(var(--safe-t) + 40px) var(--gutter) calc(var(--safe-b) + 40px)',
        width: '100%', maxWidth: 460, margin: '0 auto',
        animation: 'enter 420ms var(--ease) both',
      }}
    >
      <div className="center" style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14 }}>
        <div style={{ filter: 'drop-shadow(0 0 34px rgba(181,168,255,0.34))' }}>
          <Logo height={54} />
        </div>
        <div className="eyebrow" style={{ margin: 0 }}>2v2 FIFA League</div>
      </div>
      {children}
    </div>
  )
}
