import { useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag, { ticketTone } from '../../components/common/Tag'
import { api } from '../../services/apiClient'
import { TICKET_STATUS } from '../../utils/format'
import { useApi } from '../../utils/useApi'
import type { Ticket } from '../../services/types'
import TicketThread from './TicketThread'

export default function SupportDetailPage() {
  const { id } = useParams()
  const { loading, error, data, reload } = useApi<{ ticket: Ticket }>(`/support/${id}`)
  const [busy, setBusy] = useState(false)
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} />
  const t = data.ticket

  const close = async () => {
    if (!window.confirm('문의를 종료할까요? 종료하면 더 이상 답변을 받을 수 없습니다.')) return
    setBusy(true)
    try { await api(`/support/${id}/close`, { method: 'POST' }); reload() } finally { setBusy(false) }
  }

  return (
    <section className="page page--narrow">
      <Link to="/support" className="back">← 문의 목록</Link>
      <header className="page__header">
        <h1 className="page__title">{t.title}</h1>
        <Tag tone={ticketTone(t.status)}>{TICKET_STATUS[t.status]}</Tag>
      </header>
      <TicketThread ticket={t} />
      {t.status !== 'CLOSED' && (
        <div className="row">
          <button className="btn btn--ghost" onClick={close} disabled={busy}>문의 종료</button>
          {t.status === 'OPEN' && <span className="muted">상담원이 확인하기 전까지 기다려 주세요.</span>}
        </div>
      )}
    </section>
  )
}
