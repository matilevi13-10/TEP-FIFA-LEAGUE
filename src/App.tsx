import { Navigate, Route, Routes } from 'react-router-dom'
import { Logo } from './components/Logo'
import { TabBar, TopNav } from './components/Nav'
import { useAuth } from './lib/auth'
import { LeagueProvider } from './lib/league'
import { SignIn } from './screens/SignIn'
import { Home } from './screens/Home'
import { TableScreen } from './screens/Table'
import { Submit } from './screens/Submit'
import { Bracket } from './screens/Bracket'
import { Admin } from './screens/Admin'

export function App() {
  const { ready, session, team, signOut } = useAuth()

  if (!ready) {
    return (
      <div style={{
        minHeight: '100dvh', display: 'grid', placeItems: 'center',
        animation: 'enter 500ms var(--ease) both',
      }}>
        <div style={{ filter: 'drop-shadow(0 0 30px rgba(181,168,255,0.28))', opacity: 0.9 }}>
          <Logo height={40} />
        </div>
      </div>
    )
  }

  if (!session) return <SignIn />

  // Signed in with Supabase but no team attached — a half-finished first login.
  if (!team) {
    return (
      <div style={{
        minHeight: '100dvh', display: 'flex', flexDirection: 'column',
        alignItems: 'center', justifyContent: 'center', gap: 18, padding: 'var(--gutter)',
      }}>
        <Logo height={40} />
        <p className="muted center" style={{ maxWidth: 300, fontSize: 14, margin: 0 }}>
          This login isn't attached to a team yet. Sign in again with your team's PIN.
        </p>
        <button className="btn btn--primary" onClick={() => void signOut()}>Start over</button>
      </div>
    )
  }

  return (
    <LeagueProvider>
      <div className="app">
        <header className="header">
          <div className="header__inner">
            <Logo height={19} />
            <TopNav />
            <button
              className="header__team"
              onClick={() => void signOut()}
              title="Sign out"
              style={{ display: 'flex', alignItems: 'center', gap: 8, minHeight: 34 }}
            >
              <span style={{ maxWidth: 130, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {team.name}
              </span>
              <span
                aria-hidden
                style={{
                  width: 27, height: 27, borderRadius: '50%', flexShrink: 0,
                  background: 'rgba(181,168,255,0.16)', border: '1px solid rgba(181,168,255,0.3)',
                  color: 'var(--accent)', display: 'grid', placeItems: 'center',
                  fontSize: 11, fontWeight: 700,
                }}
              >
                {team.name.slice(0, 2).toUpperCase()}
              </span>
            </button>
          </div>
        </header>

        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/table" element={<TableScreen />} />
          <Route path="/submit" element={<Submit />} />
          <Route path="/bracket" element={<Bracket />} />
          <Route path="/admin" element={<Admin />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>

        <TabBar />
      </div>
    </LeagueProvider>
  )
}
