import { useState, type FormEvent } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag, { ticketTone } from '../../components/common/Tag'
import { ApiError, api } from '../../services/apiClient'
import type { Ticket, TicketSummary } from '../../services/types'
import { TICKET_STATUS, dateTime } from '../../utils/format'
import { useApi } from '../../utils/useApi'
import TicketThread from './TicketThread'

const FILTERS: [string, string][] = [['', '전체'], ['OPEN', '접수'], ['IN_PROGRESS', '상담 중'], ['ANSWERED', '답변 완료'], ['CLOSED', '종료']]

// 상담 관리자 문의 화면: 왼쪽 목록에서 고르면 오른쪽에서 본문을 읽고 바로 답변한다.
export default function AdminSupportPage() {
  const { id } = useParams()
  const navigate = useNavigate()
  const [status, setStatus] = useState('OPEN')
  const list = useApi<{ tickets: TicketSummary[] }>(`/admin/support${status ? `?status=${status}` : ''}`)
  const selectedId = id ? Number(id) : null

  return (
    <section className="page page--wide">
      <h1 className="page__title">문의 답변</h1>
      <div className="filters" role="tablist">
        {FILTERS.map(([v, l]) => (
          <button key={v} role="tab" aria-selected={status === v} className={`chip ${status === v ? 'chip--on' : ''}`}
                  onClick={() => setStatus(v)}>{l}</button>
        ))}
      </div>

      <div className="split">
        <div className="split__list">
          {list.loading ? <Loading /> : list.error || !list.data ? <ErrorState error={list.error} onRetry={list.reload} /> : (
            list.data.tickets.length === 0 ? <div className="panel panel--muted"><p className="muted">해당하는 문의가 없습니다.</p></div> : (
              <ul className="rows">
                {list.data.tickets.map((t) => (
                  <li key={t.id}>
                    <Link to={`/admin/support/${t.id}`} className={`rows__item rows__item--stack ${t.id === selectedId ? 'is-selected' : ''}`}>
                      <span className="rows__top">
                        <span className="rows__main">{t.title}</span>
                        <Tag tone={ticketTone(t.status)}>{TICKET_STATUS[t.status]}</Tag>
                      </span>
                      <span className="rows__preview">{t.content}</span>
                      <span className="muted">{t.customer?.name ?? t.customer_name} · {t.category_label} · {dateTime(t.created_at)}</span>
                    </Link>
                  </li>
                ))}
              </ul>
            )
          )}
        </div>
        <div className="split__detail">
          {selectedId ? (
            <TicketPanel key={selectedId} id={selectedId} onChanged={list.reload} onClose={() => navigate('/admin/support')} />
          ) : (
            <div className="panel panel--muted"><p className="muted">왼쪽에서 문의를 선택하면 내용과 답변 창이 여기에 열립니다.</p></div>
          )}
        </div>
      </div>
    </section>
  )
}

function TicketPanel({ id, onChanged, onClose }: { id: number; onChanged: () => void; onClose: () => void }) {
  const { loading, error, data, reload } = useApi<{ ticket: Ticket & { customer?: { id: number; name: string; email: string } } }>(`/admin/support/${id}`)
  const [reply, setReply] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} />
  const t = data.ticket

  const refresh = () => { reload(); onChanged() }
  const send = async (e: FormEvent) => {
    e.preventDefault(); setBusy(true); setErr(null)
    try { await api(`/admin/support/${id}/replies`, { method: 'POST', body: { content: reply } }); setReply(''); refresh() }
    catch (ex) { setErr((ex as ApiError).details?.content ?? (ex as ApiError).message) } finally { setBusy(false) }
  }
  const setStatus = async (status: string) => {
    try { await api(`/admin/support/${id}`, { method: 'PATCH', body: { status } }); refresh() }
    catch (ex) { setErr((ex as ApiError).message) }
  }

  return (
    <article className="panel ticket-panel">
      <header className="panel__head">
        <h2>{t.title}</h2>
        <button type="button" className="btn btn--ghost btn--sm" onClick={onClose} aria-label="닫기">닫기</button>
      </header>
      <p className="muted">
        {t.customer ? <Link to={`/admin/customers/${t.customer.id}`}>{t.customer.name}</Link> : t.customer_name}
        {t.customer && ` (${t.customer.email})`} · <Tag tone={ticketTone(t.status)}>{TICKET_STATUS[t.status]}</Tag>
      </p>
      <TicketThread ticket={t} customerLabel={t.customer?.name ?? t.customer_name ?? '고객'} />
      {t.status !== 'CLOSED' ? (
        <form className="form" onSubmit={send}>
          <label>답변 작성
            <textarea rows={5} value={reply} onChange={(e) => setReply(e.target.value)} aria-invalid={!!err}
                      placeholder="고객에게 보낼 답변을 적어 주세요. 고객에게는 작성자가 '상담원'으로 표시됩니다." />
          </label>
          {err && <span className="field-error">{err}</span>}
          <div className="row wrap">
            <button className="btn" disabled={busy || reply.trim().length < 2}>답변 등록</button>
            {t.status === 'OPEN' && <button type="button" className="btn btn--ghost" onClick={() => setStatus('IN_PROGRESS')}>상담 중으로 표시</button>}
            <button type="button" className="btn btn--ghost" onClick={() => setStatus('CLOSED')}>종료</button>
          </div>
        </form>
      ) : <p className="muted">종료된 문의입니다.</p>}
    </article>
  )
}
