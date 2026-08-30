import { createContext, useCallback, useContext, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { IconAlert, IconCheck } from './Icons'

type Tone = 'good' | 'bad' | 'plain'
interface Toast { id: number; message: string; tone: Tone }

const ToastContext = createContext<((message: string, tone?: Tone) => void) | null>(null)

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([])
  const nextId = useRef(1)

  const push = useCallback((message: string, tone: Tone = 'plain') => {
    const id = nextId.current++
    setToasts((current) => [...current, { id, message, tone }])
    window.setTimeout(() => setToasts((current) => current.filter((t) => t.id !== id)), 4000)
  }, [])

  const value = useMemo(() => push, [push])

  return (
    <ToastContext.Provider value={value}>
      {children}
      <div className="toasts" role="status" aria-live="polite">
        {toasts.map((toast) => (
          <div key={toast.id} className={`toast toast--${toast.tone}`}>
            {toast.tone !== 'plain' && (
              <span style={{ color: toast.tone === 'good' ? 'var(--accent)' : 'var(--danger)', display: 'flex' }}>
                <span style={{ width: 18, height: 18, display: 'block' }}>
                  {toast.tone === 'good' ? <IconCheck /> : <IconAlert />}
                </span>
              </span>
            )}
            <span className="toast__text">{toast.message}</span>
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  )
}

export function useToast() {
  const context = useContext(ToastContext)
  if (!context) throw new Error('useToast must be used inside ToastProvider')
  return context
}
