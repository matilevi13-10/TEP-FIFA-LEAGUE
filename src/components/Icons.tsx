/** 24px stroke icons, sized by the parent via CSS. */
const base = {
  viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor',
  strokeWidth: 1.7, strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const,
}

export const IconHome = () => (
  <svg {...base}><path d="M3.5 10.2 12 3.5l8.5 6.7V20a1 1 0 0 1-1 1h-4.6v-6.1H9.1V21H4.5a1 1 0 0 1-1-1Z" /></svg>
)
export const IconTable = () => (
  <svg {...base}><path d="M3.5 5.5h17M3.5 12h17M3.5 18.5h17M9 5.5V19" /></svg>
)
export const IconSubmit = () => (
  <svg {...base}><circle cx="12" cy="12" r="8.5" /><path d="M12 8.4v7.2M8.4 12h7.2" /></svg>
)
export const IconBracket = () => (
  <svg {...base}><path d="M3.5 5h4.2a2 2 0 0 1 2 2v10a2 2 0 0 0 2 2h1.8M3.5 19h4.2M14.5 12h6M17.6 9l3 3-3 3" /></svg>
)
export const IconAdmin = () => (
  <svg {...base}><path d="M12 3.2 4.8 6v6c0 4.2 3 7.6 7.2 8.8 4.2-1.2 7.2-4.6 7.2-8.8V6Z" /><path d="M9.3 12.1l1.9 1.9 3.6-3.7" /></svg>
)
export const IconCheck = () => (
  <svg {...base}><path d="M4.5 12.5 9.5 17.5 19.5 7" /></svg>
)
export const IconClose = () => (
  <svg {...base}><path d="M6 6l12 12M18 6 6 18" /></svg>
)
export const IconChevron = () => (
  <svg {...base}><path d="M9 5.5 15.5 12 9 18.5" /></svg>
)
export const IconTrophy = () => (
  <svg {...base}>
    <path d="M7.5 4h9v5a4.5 4.5 0 0 1-9 0Z" />
    <path d="M7.5 5.5H5A1.5 1.5 0 0 0 3.5 7c0 2 1.6 3.4 4 3.6M16.5 5.5H19A1.5 1.5 0 0 1 20.5 7c0 2-1.6 3.4-4 3.6" />
    <path d="M12 13.5V17M9 20.5h6M10 17h4l.6 3.5h-5.2Z" />
  </svg>
)
export const IconAlert = () => (
  <svg {...base}><circle cx="12" cy="12" r="8.5" /><path d="M12 7.6v5M12 15.9v.1" /></svg>
)
export const IconSpinner = () => (
  <svg {...base} className="spin"><path d="M12 3.5a8.5 8.5 0 1 0 8.5 8.5" /></svg>
)
export const IconBackspace = () => (
  <svg {...base}><path d="M8.6 5.5h10.4a1.5 1.5 0 0 1 1.5 1.5v10a1.5 1.5 0 0 1-1.5 1.5H8.6L3.2 12Z" /><path d="M11.8 9.8 16 14M16 9.8 11.8 14" /></svg>
)
export const IconChat = () => (
  <svg {...base} strokeWidth={1.9}><path d="M20.5 11.6c0 4-3.8 7.2-8.5 7.2a9.7 9.7 0 0 1-2.4-.3L4.5 20.5l1.3-3.6a6.8 6.8 0 0 1-2.3-5c0-4 3.8-7.3 8.5-7.3s8.5 3.2 8.5 7.2Z" /></svg>
)
export const IconSend = () => (
  <svg {...base}><path d="M4.5 12h14M13 6.5 18.5 12 13 17.5" /></svg>
)
export const IconTeams = () => (
  <svg {...base}><circle cx="9" cy="8.2" r="3.2" /><path d="M3.6 19.4c0-3 2.4-5.2 5.4-5.2s5.4 2.2 5.4 5.2" /><path d="M16.2 5.4a3.2 3.2 0 0 1 0 6.1M17.4 14.6c1.8.6 3 2.4 3 4.8" /></svg>
)

