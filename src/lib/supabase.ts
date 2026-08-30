import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

/** False when .env is missing, so the app can explain itself instead of dying. */
export const isConfigured = Boolean(url && anonKey)

export const supabase = createClient(url ?? 'https://placeholder.supabase.co', anonKey ?? 'placeholder', {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
})

/** Postgres RAISE messages are already written for players, so pass them through. */
export function readableError(error: unknown): string {
  if (!error) return 'Something went wrong.'
  const message = (error as { message?: string }).message ?? String(error)
  if (/email not confirmed/i.test(message)) {
    return 'Supabase still has email confirmation switched on — turn it off under Authentication → Sign In / Providers.'
  }
  if (/signups not allowed|signup is disabled/i.test(message)) {
    return 'Supabase has new sign-ups disabled — enable them under Authentication → Sign In / Providers.'
  }
  if (/failed to fetch|networkerror/i.test(message)) return 'No connection. Check your signal and try again.'
  // PGRST202: the RPC does not exist, which in practice means schema.sql was never run.
  if (/could not find the function|schema cache|PGRST202/i.test(message)) {
    return 'The database has not been set up yet. Run supabase/schema.sql in the Supabase SQL Editor.'
  }
  if (/relation .* does not exist/i.test(message)) {
    return 'The database is missing its tables. Run supabase/schema.sql in the Supabase SQL Editor.'
  }
  return message.replace(/^(?:error|postgrest error|database error):\s*/i, '')
}
