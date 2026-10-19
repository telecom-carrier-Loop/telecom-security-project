import { useState, type FormEvent } from 'react'
import { Link, useParams } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag, { ticketTone } from '../../components/common/Tag'
import { ApiError, api } from '../../services/apiClient'
import type { Ticket } from '../../services/types'
import { TICKET_STATUS } from '../../utils/format'
import { useApi } from '../../utils/useApi'
import TicketThread from './TicketThread'

export default function AdminSupportDetailPage() {
  const { id } = useParams()
  const { loading, error, data, reload } = useApi<{ ticket: Ticket }>(`/admin/support/${id}`)
  const [reply, setReply] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} />
  const t = data.ticket

  const send = async (e: FormEvent) => {
    e.preventDefault(); setBusy(true); setErr(null)
    try { await api(`/admin/support/${id}/replies`, { method: 'POST', body: { content: reply } }); setReply(''); reload() }
    catch (ex) { setErr((ex as ApiError).details?.content ?? (ex as ApiError).message) } finally { setBusy(false) }
  }
  const setStatus = async (status: string) => { await api(`/admin/support/${id}`, { method: 'PATCH', body: { status } }); reload() }

  return (
    <section className="page page--narrow">
      <Link to="/admin/support" className="back">← 문의 목록</Link>
      <header className="page__header">
        <h1 className="page__title">{t.title}</h1>
        <Tag tone={ticketTone(t.status)}>{TICKET_STATUS[t.status]}</Tag>
      </header>
      <TicketThread ticket={t} customerLabel={t.customer_name} />
      {t.status !== 'CLOSED' && (
        <form className="panel form" onSubmit={send}>
          <h2>답변 작성</h2>
          <textarea rows={5} value={reply} onChange={(e) => setReply(e.target.value)} aria-invalid={!!err} />
          {err && <span className="field-error">{err}</span>}
          <div className="row">
            <button className="btn" disabled={busy || reply.trim().length < 2}>답변 등록</button>
            {t.status === 'OPEN' && <button type="button" className="btn btn--ghost" onClick={() => setStatus('IN_PROGRESS')}>상담 중으로 표시</button>}
            <button type="button" className="btn btn--ghost" onClick={() => setStatus('CLOSED')}>종료</button>
          </div>
        </form>
      )}
    </section>
  )
}
