import { NavLink } from 'react-router-dom'
import { useAuth } from '../lib/auth'
import { useLeague } from '../lib/league'
import { IconAdmin, IconBracket, IconHome, IconSubmit, IconTeams } from './Icons'

interface Item { to: string; label: string; icon: JSX.Element; badge?: number }

function useNavItems(): Item[] {
  const { player } = useAuth()
  const { settings, pendingForMe, incomingRequests } = useLeague()
  const inPlayoffs = settings?.phase === 'playoffs' || settings?.phase === 'complete'

  const items: Item[] = [
    { to: '/', label: 'League', icon: <IconHome />, badge: pendingForMe.length + incomingRequests.length },
    { to: '/teams', label: 'Teams', icon: <IconTeams />, badge: incomingRequests.length },
  ]
  if (player?.team_id) items.push({ to: '/submit', label: 'Submit', icon: <IconSubmit /> })
  if (inPlayoffs) items.push({ to: '/bracket', label: 'Bracket', icon: <IconBracket /> })
  if (player?.is_admin) items.push({ to: '/admin', label: 'Admin', icon: <IconAdmin /> })
  return items
}

/** Thumb bar on phones and tablets. Hidden at ≥1024px by the stylesheet. */
export function TabBar() {
  const items = useNavItems()
  return (
    <nav className="tabs" aria-label="Main">
      <div className="tabs__inner">
        {items.map((item) => (
          <NavLink
            key={item.to}
            to={item.to}
            end={item.to === '/'}
            className={({ isActive }) => `tab${isActive ? ' tab--on' : ''}`}
          >
            {item.icon}
            <span>{item.label}</span>
            {item.badge ? <span className="tab__dot">{item.badge}</span> : null}
          </NavLink>
        ))}
      </div>
    </nav>
  )
}

/** The same destinations as a header row on desktop. */
export function TopNav() {
  const items = useNavItems()
  return (
    <nav className="topnav" aria-label="Main">
      {items.map((item) => (
        <NavLink
          key={item.to}
          to={item.to}
          end={item.to === '/'}
          className={({ isActive }) => `topnav__link${isActive ? ' topnav__link--on' : ''}`}
        >
          {item.icon}
          <span>{item.label}</span>
          {item.badge ? <span className="badge" style={{ marginLeft: 2 }}>{item.badge}</span> : null}
        </NavLink>
      ))}
    </nav>
  )
}
