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
import { Schedule } from './screens/Schedule'
import { Submit } from './screens/Submit'
import { Bracket } from './screens/Bracket'
import { Admin } from './screens/Admin'

export function App() {
  const { ready, session, player, profileError, signOut, reloadPlayer } = useAuth()

  if (!ready) {
    return (
      <div style={{ minHeight: '100dvh', display: 'grid', placeItems: 'center' }}>
        <div style={{ filter: 'drop-shadow(0 0 30px rgba(181,168,255,0.28))', opacity: 0.9 }}>
          <Logo height={40} />
        </div>
      </div>
    )
  }

  if (!session) return <SignIn />

  // A trigger creates the profile when the account is created, and
  // ensure_account() repairs anything older, so this is genuinely rare. When it
  // does happen it says why rather than shrugging.
  if (!player) {
    return (
      <div style={{ minHeight: '100dvh', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 'var(--s-5)', padding: 'var(--gutter)' }}>
        <Logo height={40} />
        <div className="card" style={{ maxWidth: '26rem' }}>
          <div className="eyebrow">Couldn't load your profile</div>
          <p className="t-subhead muted" style={{ margin: 0 }}>
            {profileError ?? 'Something went wrong. Check your connection and try again.'}
          </p>
        </div>
        <div className="row" style={{ gap: 'var(--s-2)' }}>
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
            <button className="header__me" onClick={() => void signOut()} title="Sign out">
              <span className="truncate" style={{ maxWidth: '8rem' }}>{player.name}</span>
              <span className="avatar" aria-hidden>{player.name.slice(0, 2).toUpperCase()}</span>
            </button>
          </div>
        </header>

        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/teams" element={<Teams />} />
          <Route path="/submit" element={<Submit />} />
          <Route path="/schedule" element={<Schedule />} />
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
