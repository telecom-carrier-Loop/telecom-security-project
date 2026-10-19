import { useState } from 'react'
import { Link } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag, { ticketTone } from '../../components/common/Tag'
import { TICKET_STATUS, dateTime } from '../../utils/format'
import type { TicketSummary } from '../../services/types'
import { useApi } from '../../utils/useApi'

const FILTERS = [['', '전체'], ['OPEN', '접수'], ['IN_PROGRESS', '상담 중'], ['ANSWERED', '답변 완료'], ['CLOSED', '종료']]

export default function AdminSupportPage() {
  const [status, setStatus] = useState('OPEN')
  const { loading, error, data, reload } = useApi<{ tickets: TicketSummary[] }>(`/admin/support${status ? `?status=${status}` : ''}`)
  return (
    <section className="page">
      <h1 className="page__title">문의 답변</h1>
      <div className="filters" role="tablist">
        {FILTERS.map(([v, l]) => (
          <button key={v} role="tab" aria-selected={status === v} className={`chip ${status === v ? 'chip--on' : ''}`}
                  onClick={() => setStatus(v)}>{l}</button>
        ))}
      </div>
      {loading ? <Loading /> : error || !data ? <ErrorState error={error} onRetry={reload} /> : (
        data.tickets.length === 0 ? <div className="panel panel--muted"><p className="muted">해당하는 문의가 없습니다.</p></div> : (
          <ul className="rows">
            {data.tickets.map((t) => (
              <li key={t.id}>
                <Link to={`/admin/support/${t.id}`} className="rows__item">
                  <span className="rows__main">{t.title}<span className="muted"> · {t.customer_name}</span></span>
                  <span className="muted">{dateTime(t.created_at)}</span>
                  <Tag tone={ticketTone(t.status)}>{TICKET_STATUS[t.status]}</Tag>
                </Link>
              </li>
            ))}
          </ul>
        )
      )}
    </section>
  )
}
