import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from './supabase'
import type { Player } from './types'

interface AuthValue {
  ready: boolean
  session: Session | null
  player: Player | null
  signUp: (username: string, email: string, password: string) => Promise<void>
  signIn: (email: string, password: string) => Promise<void>
  signOut: () => Promise<void>
  reloadPlayer: () => Promise<void>
}

const AuthContext = createContext<AuthValue | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [player, setPlayer] = useState<Player | null>(null)
  const [ready, setReady] = useState(false)

  const loadPlayer = useCallback(async (uid: string | undefined) => {
    if (!uid) {
      setPlayer(null)
      return
    }
    const { data } = await supabase.from('players').select('*').eq('user_id', uid).maybeSingle()
    setPlayer((data as Player) ?? null)
  }, [])

  useEffect(() => {
    let alive = true
    supabase.auth.getSession().then(async ({ data }) => {
      if (!alive) return
      setSession(data.session)
      await loadPlayer(data.session?.user.id)
      if (alive) setReady(true)
    })

    const { data: sub } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next)
      void loadPlayer(next?.user.id)
    })
    return () => {
      alive = false
      sub.subscription.unsubscribe()
    }
  }, [loadPlayer])

  const signUp = useCallback(
    async (username: string, email: string, password: string) => {
      const { error } = await supabase.auth.signUp({ email: email.trim(), password })
      if (error) {
        // Already registered — sign in and attach the username instead.
        if (!/already registered|already exists/i.test(error.message)) throw error
        const { error: signInError } = await supabase.auth.signInWithPassword({
          email: email.trim(), password,
        })
        if (signInError) throw signInError
      }

      // The username lives in our schema, not in Supabase Auth.
      const { error: claimError } = await supabase.rpc('claim_account', { p_username: username.trim() })
      if (claimError) throw claimError

      const { data: fresh } = await supabase.auth.getSession()
      setSession(fresh.session)
      await loadPlayer(fresh.session?.user.id)
    },
    [loadPlayer],
  )

  const signIn = useCallback(
    async (email: string, password: string) => {
      const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password })
      if (error) throw error
      const { data: fresh } = await supabase.auth.getSession()
      setSession(fresh.session)
      await loadPlayer(fresh.session?.user.id)
    },
    [loadPlayer],
  )

  const signOut = useCallback(async () => {
    await supabase.auth.signOut()
    setSession(null)
    setPlayer(null)
  }, [])

  const reloadPlayer = useCallback(async () => {
    const { data } = await supabase.auth.getSession()
    await loadPlayer(data.session?.user.id)
  }, [loadPlayer])

  const value = useMemo(
    () => ({ ready, session, player, signUp, signIn, signOut, reloadPlayer }),
    [ready, session, player, signUp, signIn, signOut, reloadPlayer],
  )
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth(): AuthValue {
  const context = useContext(AuthContext)
  if (!context) throw new Error('useAuth must be used inside AuthProvider')
  return context
}
