import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from './supabase'
import type { Player } from './types'

/**
 * Turns a Supabase error into something worth showing. In dev the code and raw
 * message come through, because guessing at a PGRST202 from a generic
 * "something went wrong" is exactly the debugging dead end this replaces.
 */
function describe(context: string, error: { code?: string; message?: string; hint?: string }): string {
  const code = error.code ?? ''
  if (code === 'PGRST202' || /schema cache|could not find the function/i.test(error.message ?? '')) {
    return 'The database is missing its setup. Run supabase/migrations/002_accounts_and_chat.sql in the Supabase SQL Editor.'
  }
  if (/relation .* does not exist|column .* does not exist/i.test(error.message ?? '')) {
    return 'The database schema is out of date. Run supabase/migrations/002_accounts_and_chat.sql in the Supabase SQL Editor.'
  }
  if (import.meta.env.DEV) {
    return `${context}: ${code ? `[${code}] ` : ''}${error.message ?? 'unknown error'}`
  }
  return `${context}. Please try again.`
}

interface AuthValue {
  ready: boolean
  session: Session | null
  player: Player | null
  /** Why the profile could not be loaded or created, for the error screen. */
  profileError: string | null
  signUp: (username: string, email: string, password: string) => Promise<void>
  signIn: (email: string, password: string) => Promise<void>
  signOut: () => Promise<void>
  reloadPlayer: () => Promise<void>
}

const AuthContext = createContext<AuthValue | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [player, setPlayer] = useState<Player | null>(null)
  const [profileError, setProfileError] = useState<string | null>(null)
  const [ready, setReady] = useState(false)

  /**
   * Loads the signed-in user's profile, creating one if it is missing. An
   * account can exist in Supabase Auth without a profile row — a sign-up
   * interrupted between signUp and claim_account, or a login predating this
   * schema. Repairing it here means "signed in but no profile" is never a
   * state the UI has to render.
   */
  /**
   * Loads the signed-in user's profile.
   *
   * A trigger on auth.users creates the row when the account is created, so
   * this normally just reads it. ensure_account() is the repair path for
   * accounts that predate the trigger, or a sign-up the trigger could not
   * complete. Every failure is reported rather than swallowed — a silent null
   * here is what produced "Couldn't finish setting up your account" with no
   * way to find out why.
   */
  const loadPlayer = useCallback(async (uid: string | undefined) => {
    if (!uid) {
      setPlayer(null)
      setProfileError(null)
      return
    }

    const read = await supabase.from('players').select('*').eq('user_id', uid).maybeSingle()
    if (read.error) {
      console.error('[TEP] reading profile failed:', read.error)
      setPlayer(null)
      setProfileError(describe('Reading your profile failed', read.error))
      return
    }
    if (read.data) {
      setPlayer(read.data as Player)
      setProfileError(null)
      return
    }

    const repair = await supabase.rpc('ensure_account')
    if (repair.error) {
      console.error('[TEP] ensure_account failed:', repair.error)
      setPlayer(null)
      setProfileError(describe('Creating your profile failed', repair.error))
      return
    }

    const after = await supabase.from('players').select('*').eq('user_id', uid).maybeSingle()
    if (after.error) {
      console.error('[TEP] re-reading profile failed:', after.error)
      setPlayer(null)
      setProfileError(describe('Reading your profile failed', after.error))
      return
    }
    setPlayer((after.data as Player) ?? null)
    setProfileError(after.data ? null : 'Your profile could not be created.')
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
      // The username rides along as user metadata so the auth trigger can build
      // the profile immediately, before the client asks for it.
      const { error } = await supabase.auth.signUp({
        email: email.trim(),
        password,
        options: { data: { username: username.trim() } },
      })
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
    () => ({ ready, session, player, profileError, signUp, signIn, signOut, reloadPlayer }),
    [ready, session, player, profileError, signUp, signIn, signOut, reloadPlayer],
  )
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth(): AuthValue {
  const context = useContext(AuthContext)
  if (!context) throw new Error('useAuth must be used inside AuthProvider')
  return context
}
