import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from './supabase'
import type { Team, TeamOption } from './types'

interface AuthValue {
  ready: boolean
  session: Session | null
  team: Team | null
  signIn: (teamId: string, pin: string) => Promise<void>
  signOut: () => Promise<void>
  reloadTeam: () => Promise<void>
}

const AuthContext = createContext<AuthValue | null>(null)

/** Sign-in picker data. Public on purpose — names only, never PIN material. */
export async function fetchTeamOptions(): Promise<TeamOption[]> {
  const { data, error } = await supabase.rpc('list_teams_for_signin')
  if (error) throw error
  return (data ?? []) as TeamOption[]
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [team, setTeam] = useState<Team | null>(null)
  const [ready, setReady] = useState(false)

  const loadTeam = useCallback(async (uid: string | undefined) => {
    if (!uid) {
      setTeam(null)
      return
    }
    const { data } = await supabase.from('teams').select('*').eq('user_id', uid).maybeSingle()
    setTeam((data as Team) ?? null)
  }, [])

  useEffect(() => {
    let alive = true
    supabase.auth.getSession().then(async ({ data }) => {
      if (!alive) return
      setSession(data.session)
      await loadTeam(data.session?.user.id)
      if (alive) setReady(true)
    })

    const { data: sub } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next)
      void loadTeam(next?.user.id)
    })
    return () => {
      alive = false
      sub.subscription.unsubscribe()
    }
  }, [loadTeam])

  const signIn = useCallback(
    async (teamId: string, pin: string) => {
      // The PIN never becomes the auth password. begin_signin checks it under a
      // rate limiter and only then hands back the team's real credentials.
      const { data, error } = await supabase.rpc('begin_signin', { p_team_id: teamId, p_pin: pin })
      if (error) throw error
      const { email, auth_key, needs_signup } = data as {
        email: string
        auth_key: string
        needs_signup: boolean
      }

      if (needs_signup) {
        const { error: signUpError } = await supabase.auth.signUp({ email, password: auth_key })
        if (signUpError) {
          // An earlier attempt created the user but never linked the team.
          if (!/already registered|already exists/i.test(signUpError.message)) throw signUpError
          const { error: retryError } = await supabase.auth.signInWithPassword({ email, password: auth_key })
          if (retryError) throw retryError
        }
        const { error: linkError } = await supabase.rpc('link_account', { p_team_id: teamId, p_pin: pin })
        if (linkError) throw linkError
      } else {
        const { error: signInError } = await supabase.auth.signInWithPassword({ email, password: auth_key })
        if (signInError) throw signInError
      }

      const { data: fresh } = await supabase.auth.getSession()
      setSession(fresh.session)
      await loadTeam(fresh.session?.user.id)
    },
    [loadTeam],
  )

  const signOut = useCallback(async () => {
    await supabase.auth.signOut()
    setSession(null)
    setTeam(null)
  }, [])

  const reloadTeam = useCallback(async () => {
    const { data } = await supabase.auth.getSession()
    await loadTeam(data.session?.user.id)
  }, [loadTeam])

  const value = useMemo(
    () => ({ ready, session, team, signIn, signOut, reloadTeam }),
    [ready, session, team, signIn, signOut, reloadTeam],
  )
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth(): AuthValue {
  const context = useContext(AuthContext)
  if (!context) throw new Error('useAuth must be used inside AuthProvider')
  return context
}
