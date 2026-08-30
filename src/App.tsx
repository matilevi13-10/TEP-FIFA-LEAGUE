import { Navigate, Route, Routes } from 'react-router-dom'
import { Logo } from './components/Logo'
import { TabBar, TopNav } from './components/Nav'
import { Chat } from './components/Chat'
import { TauntPrompt } from './components/TauntPrompt'
import { useAuth } from './lib/auth'
import { LeagueProvider } from './lib/league'
import { SignIn } from './screens/SignIn'
import { Home } from './screens/Home'
import { Teams } from './screens/Teams'
import { Submit } from './screens/Submit'
import { Bracket } from './screens/Bracket'
import { Admin } from './screens/Admin'

export function App() {
  const { ready, session, player, signOut, reloadPlayer } = useAuth()

  if (!ready) {
    return (
      <div style={{ minHeight: '100dvh', display: 'grid', placeItems: 'center', animation: 'enter 500ms var(--ease) both' }}>
        <div style={{ filter: 'drop-shadow(0 0 30px rgba(181,168,255,0.28))', opacity: 0.9 }}>
          <Logo height={40} />
        </div>
      </div>
    )
  }

  if (!session) return <SignIn />

  // The profile is created on demand in loadPlayer, so this only shows if that
  // call could not reach Supabase at all.
  if (!player) {
    return (
      <div style={{ minHeight: '100dvh', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 18, padding: 'var(--gutter)' }}>
        <Logo height={40} />
        <p className="muted center" style={{ maxWidth: 320, fontSize: 14, margin: 0 }}>
          Couldn't finish setting up your account. Check your connection and try again.
        </p>
        <div className="row" style={{ gap: 8 }}>
          <button className="btn btn--primary" onClick={() => void reloadPlayer()}>Try again</button>
          <button className="btn btn--ghost" onClick={() => void signOut()}>Sign out</button>
        </div>
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
                {player.name}
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
                {player.name.slice(0, 2).toUpperCase()}
              </span>
            </button>
          </div>
        </header>

        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/teams" element={<Teams />} />
          <Route path="/submit" element={<Submit />} />
          <Route path="/bracket" element={<Bracket />} />
          <Route path="/admin" element={<Admin />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>

        <TabBar />
        <Chat />
        <TauntPrompt />
      </div>
    </LeagueProvider>
  )
}
