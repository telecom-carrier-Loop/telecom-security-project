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
      tier: { code: string; name: string; rank: number; earn_rate_bp: number }
      tiers: { name: string; rank: number; earn_rate_bp: number; min_monthly_fee: number; admin_only?: boolean }[]
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
  protection: { active_blocks: number; locked_accounts: number; privilege_violations: number }
}

export type AccountStatus = 'ACTIVE' | 'LOCKED' | 'DEACTIVATED'

export interface CustomerRow {
  id: number
  name: string
  email: string
  is_active: boolean
  status: AccountStatus
  locked_at: string | null
  lock_reason: string | null
  login_failures_15m: number
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
  status: AccountStatus
  locked_at: string | null
  lock_reason: string | null
  login_failures_15m: number
  created_at: string
  last_login_at: string | null
  subscription: { phone_number: string; plan: Plan; started_on: string } | null
  membership: { tier: string; rank: number; point_balance: number } | null
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

export interface IpBlock {
  id: number
  ip: string
  reason: string
  source: 'MANUAL' | 'AUTOMATION'
  workflow: string | null
  created_at: string
  expires_at: string | null
  released_at: string | null
  status: 'ACTIVE' | 'EXPIRED' | 'RELEASED'
  hit_count: number
  last_hit_at: string | null
  firewall_status: 'SKIPPED' | 'PENDING' | 'SYNCED' | 'FAILED'
}

export interface WhitelistEntry { id: number; cidr: string; memo: string | null; created_at: string }

export interface PrivilegeData {
  allowlist_configured: boolean
  allowlist_size: number
  violations: number
  admins: { id: number; name: string; email: string; is_self: boolean; in_allowlist: boolean | null;
    last_login_at: string | null; created_at: string }[]
}

export interface AutomationWorkflow {
  key: string
  name: string
  webhook: string | null
  api: string | null
  last_at: string | null
  today: number
  week: number
  by_action: Record<string, number>
}

export interface AutomationLog {
  id: number
  created_at: string
  workflow: string
  action: string
  action_label: string
  target_type: 'ip' | 'user' | 'incident' | string
  target: string
  result: 'DONE' | 'ALREADY' | 'SKIPPED' | string
  reason: string | null
}

export type NoticeCategory = 'GENERAL' | 'MAINTENANCE' | 'EVENT' | 'SECURITY'
export interface Notice {
  id: number
  category: NoticeCategory
  category_label: string
  title: string
  is_pinned: boolean
  is_published: boolean
  published_at: string | null
  updated_at: string
  view_count: number
  summary?: string
  content?: string
}

export interface ShopItem {
  id: number
  name: string
  description: string | null
  category: 'GOODS' | 'DATA' | 'COUPON'
  price_points: number
  stock: number | null
  min_tier_rank: number
  is_active: boolean
  sold_out: boolean
  available: boolean | null
  sold?: number
}
export interface ShopOrder { id: number; item: string; points: number; status: string; code: string; created_at: string }
