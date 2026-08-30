import { useState } from 'react'
import { Logo } from '../components/Logo'
import { useAuth } from '../lib/auth'
import { isConfigured, readableError } from '../lib/supabase'
import { haptic } from '../lib/format'

type Mode = 'in' | 'up'

export function SignIn() {
  const { signIn, signUp } = useAuth()
  const [mode, setMode] = useState<Mode>('in')
  const [username, setUsername] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const creating = mode === 'up'
  const ready = creating
    ? username.trim().length > 0 && email.trim().length > 3 && password.length >= 6
    : email.trim().length > 3 && password.length > 0

  const submit = async (event: React.FormEvent) => {
    event.preventDefault()
    if (!ready || busy) return
    setBusy(true)
    setError(null)
    try {
      if (creating) await signUp(username, email, password)
      else await signIn(email, password)
      haptic([10, 40, 10])
    } catch (cause) {
      setError(readableError(cause))
      haptic([40, 30, 40])
    } finally {
      setBusy(false)
    }
  }

  if (!isConfigured) {
    return (
      <Shell>
        <div className="card" style={{ textAlign: 'left' }}>
          <div className="eyebrow">Setup needed</div>
          <p style={{ margin: 0 }}>
            This build has no Supabase credentials. Locally, put them in <code>.env</code> and restart.
            On Amplify, set them under App settings &rarr; Environment variables, then redeploy.
          </p>
        </div>
      </Shell>
    )
  }

  return (
    <Shell>
      <form className="card stack" onSubmit={submit}>
        {creating && (
          <div className="field">
            <label className="field__label" htmlFor="username">Username</label>
            <input
              id="username" className="input" autoFocus autoCapitalize="none" maxLength={40}
              autoComplete="username" placeholder="What everyone calls you"
              value={username} onChange={(e) => setUsername(e.target.value)}
            />
          </div>
        )}

        <div className="field">
          <label className="field__label" htmlFor="email">Email</label>
          <input
            id="email" className="input" type="email" autoCapitalize="none" autoCorrect="off"
            autoComplete="email" autoFocus={!creating} placeholder="you@example.com"
            value={email} onChange={(e) => setEmail(e.target.value)}
          />
        </div>

        <div className="field">
          <label className="field__label" htmlFor="password">Password</label>
          <input
            id="password" className="input" type="password"
            autoComplete={creating ? 'new-password' : 'current-password'}
            placeholder={creating ? 'At least 6 characters' : ''}
            value={password} onChange={(e) => setPassword(e.target.value)}
          />
        </div>

        {error && <p style={{ margin: 0, color: 'var(--danger)', fontSize: 13.5 }}>{error}</p>}

        <button className="btn btn--primary btn--block" type="submit" disabled={!ready || busy}>
          {busy ? (creating ? 'Creating your account…' : 'Signing in…') : creating ? 'Create account' : 'Sign in'}
        </button>

        {creating && (
          <p className="dim center" style={{ margin: 0, fontSize: 12.5 }}>
            Your username is how you show up in the table, the chat and on your team.
          </p>
        )}
      </form>

      <button
        className="btn btn--quiet"
        onClick={() => { haptic(); setMode(creating ? 'in' : 'up'); setError(null) }}
      >
        {creating ? 'I already have an account' : "First time? Create an account"}
      </button>
    </Shell>
  )
}

function Shell({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        minHeight: '100dvh', display: 'flex', flexDirection: 'column',
        alignItems: 'center', justifyContent: 'center', gap: 20,
        padding: 'calc(var(--safe-t) + 40px) var(--gutter) calc(var(--safe-b) + 40px)',
        width: '100%', maxWidth: 420, margin: '0 auto',
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
