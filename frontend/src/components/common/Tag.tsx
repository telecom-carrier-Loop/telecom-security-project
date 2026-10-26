// 상태 배지. tone: neutral | ok | warn | danger | info
import type { ReactNode } from 'react'
import { SEVERITY_LABEL } from '../../utils/format'

export type Tone = 'neutral' | 'ok' | 'warn' | 'danger' | 'info'

export default function Tag({ tone = 'neutral', children }: { tone?: Tone; children: ReactNode }) {
  return <span className={`tag tag--${tone}`}>{children}</span>
}

const TICKET_TONE: Record<string, Tone> = { OPEN: 'info', IN_PROGRESS: 'warn', ANSWERED: 'ok', CLOSED: 'neutral' }
const PAYMENT_TONE: Record<string, Tone> = { SUCCEEDED: 'ok', FAILED: 'danger', PENDING: 'warn', CANCELED: 'neutral', REFUNDED: 'neutral',
  PAID: 'ok', UNPAID: 'warn', OVERDUE: 'danger' }
const INCIDENT_TONE: Record<string, Tone> = { OPEN: 'danger', INVESTIGATING: 'warn', RESOLVED: 'ok', CLOSED: 'neutral' }
const SEVERITY_TONE: Record<string, Tone> = { critical: 'danger', high: 'danger', medium: 'warn', low: 'neutral', info: 'neutral' }

export const ticketTone = (s: string): Tone | undefined => TICKET_TONE[s]
export const paymentTone = (s: string): Tone | undefined => PAYMENT_TONE[s]
export const incidentTone = (s: string): Tone | undefined => INCIDENT_TONE[s]
export const severityTone = (s: string): Tone | undefined => SEVERITY_TONE[s]

// 심각도: 색만으로 구분하지 않도록 모양(◆▲●○)과 글자를 함께 쓴다
const SEV_SHAPE: Record<string, ReactNode> = {
  critical: <path d="M6 0.6 11.4 6 6 11.4 0.6 6z" fill="currentColor" />,
  high: <path d="M6 1 11 10.5H1z" fill="currentColor" />,
  medium: <circle cx="6" cy="6" r="4.8" fill="currentColor" />,
  low: <circle cx="6" cy="6" r="4.2" fill="none" stroke="currentColor" strokeWidth="1.6" />,
  info: <><rect x="5" y="1.2" width="2" height="6.5" fill="currentColor" /><rect x="5" y="9" width="2" height="2" fill="currentColor" /></>,
}
export function SeverityTag({ severity }: { severity: string }) {
  return (
    <span className={`sev sev--${severity}`}>
      <svg width="11" height="11" viewBox="0 0 12 12" aria-hidden="true">{SEV_SHAPE[severity] ?? SEV_SHAPE.info}</svg>
      {SEVERITY_LABEL[severity as keyof typeof SEVERITY_LABEL] ?? severity}
    </span>
  )
}
