// 상태 배지. tone: neutral | ok | warn | danger | info
import type { ReactNode } from 'react'

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
