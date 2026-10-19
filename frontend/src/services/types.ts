// API 응답 데이터 타입 (docs/contracts/*-api.md 와 backend 응답 기준)

export type Role = 'CUSTOMER' | 'ADMIN'

export interface User {
  id: number
  email: string
  name: string
  role: Role
}

export interface Profile extends User {
  membership_joined: boolean
  created_at: string | null
  previous_login_at: string | null
  failed_attempts_before_login: number
  password_changed_at: string | null
}

export interface Plan {
  id: number
  code: string
  name: string
  monthly_fee: number
  data_mb: number
  voice_minutes: number
  network: string
}

export interface Usage {
  period: string
  data_used_mb: number
  data_limit_mb: number
  voice_used_minutes: number
  voice_limit_minutes: number
}

export interface Invoice {
  id: number
  period: string
  amount: number
  due_date: string
  status: 'UNPAID' | 'PAID' | 'OVERDUE' | 'CANCELED'
}

export type PaymentStatus = 'PENDING' | 'SUCCEEDED' | 'FAILED' | 'CANCELED' | 'REFUNDED'

export interface Payment {
  id: number
  invoice_id: number
  amount: number
  status: PaymentStatus
  method: string
  created_at: string
  period: string
  transaction_ref: string
  customer_name?: string
  events?: { type: string; to_status: string; detail: string | null; at: string }[]
}

export type TicketStatus = 'OPEN' | 'IN_PROGRESS' | 'ANSWERED' | 'CLOSED'

export interface TicketSummary {
  id: number
  category: string
  title: string
  status: TicketStatus
  created_at: string
  updated_at: string
  category_label?: string
  customer_name?: string
  customer?: { id: number; name: string; email: string }
  content?: string
  reply_count?: number
}

export interface Ticket extends TicketSummary {
  content: string
  replies: { id: number; content: string; author: string; created_at: string }[]
}

export interface DashboardSummary {
  user: Profile
  subscription: { phone_number: string; plan: Plan } | null
  usage: Usage | null
  billing: { amount_due: number; next_due_date: string | null; unpaid_invoices: Invoice[] }
  membership: { tier: string; tier_code: string; point_balance: number } | null
  recent_tickets: TicketSummary[]
  recent_payments: Payment[]
}

export type Membership =
  | { joined: false }
  | {
      joined: true
      tier: { code: string; name: string; rank: number }
      next_tier: { name: string; min_monthly_fee: number } | null
      point_balance: number
      joined_at: string
    }

export interface Benefit {
  id: number
  name: string
  partner: string
  required_points: number
  monthly_limit: number
  used_this_month: number
  available: boolean
  unavailable_reason: string | null
}

export interface BenefitPolicy {
  id: number
  name: string
  partner: string
  required_points: number
  min_tier_rank: number
  monthly_limit: number
  is_active: boolean
}

export interface PointTransaction {
  id: number
  amount: number
  balance_after: number
  kind: 'EARN' | 'REDEEM' | 'REVERSE'
  memo: string | null
  created_at: string
}

export interface Redemption {
  id: number
  code: string
  benefit: string
  partner: string
  points_spent: number
  status: string
  created_at: string
}

export type Severity = 'info' | 'low' | 'medium' | 'high' | 'critical'
export type IncidentStatus = 'OPEN' | 'INVESTIGATING' | 'RESOLVED' | 'CLOSED'

export interface Incident {
  id: number
  source: string
  event_id: string
  event_type: string
  severity: Severity
  title: string
  status: IncidentStatus
  asset: { host: string | null; service: string | null }
  assigned_to: { id: number; name: string } | null
  detected_at: string
  resolved_at: string | null
  created_at: string
}

export interface IncidentDetail extends Incident {
  description: string | null
  scenario_id: string | null
  request_id: string | null
  evidence: Record<string, unknown> | null
  histories: { id: number; action: string; note: string | null; actor: string; at: string }[]
}

export interface AdminDashboard {
  customers: { active: number; new_7d: number; login_failures_15m: number }
  support: { waiting: number; oldest: TicketSummary[] }
  billing: { unpaid_count: number; unpaid_amount: number }
  incidents: { open: number; by_severity: Record<Severity, number> }
}

export interface CustomerRow {
  id: number
  name: string
  email: string
  is_active: boolean
  created_at: string
  last_login_at: string | null
  plan: string | null
  membership: string | null
  unpaid_amount: number
  open_tickets: number
}

export interface CustomerDetail {
  id: number
  name: string
  email: string
  is_active: boolean
  created_at: string
  last_login_at: string | null
  subscription: { phone_number: string; plan: Plan; started_on: string } | null
  membership: { tier: string; point_balance: number } | null
  unpaid_amount: number
  invoices: Invoice[]
  tickets: { id: number; title: string; status: TicketStatus; created_at: string }[]
  payments: Payment[]
}

export interface MonitoringLink {
  key: string
  name: string
  url: string | null
  description: string
  env: string
}
