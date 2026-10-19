import { useState, type ChangeEvent, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag, { ticketTone } from '../../components/common/Tag'
import { ApiError, api } from '../../services/apiClient'
import type { Ticket, TicketSummary } from '../../services/types'
import { TICKET_STATUS, dateTime } from '../../utils/format'
import { useApi } from '../../utils/useApi'

export default function SupportPage() {
  const navigate = useNavigate()
  const list = useApi<{ tickets: TicketSummary[] }>('/support')
  const cats = useApi<{ categories: { code: string; label: string }[] }>('/support/categories')
  const [writing, setWriting] = useState(false)
  const [form, setForm] = useState({ category: 'GENERAL', title: '', content: '' })
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [busy, setBusy] = useState(false)

  if (list.loading || cats.loading) return <Loading />
  if (list.error || !list.data) return <ErrorState error={list.error} onRetry={list.reload} />
  const set = (k: 'category' | 'title' | 'content') => (e: ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) => { setForm({ ...form, [k]: e.target.value }); setErrors({ ...errors, [k]: null }) }

  const submit = async (e: FormEvent) => {
    e.preventDefault()
    setBusy(true)
    try {
      const d = await api<{ ticket: Ticket }>('/support', { method: 'POST', body: form })
      navigate(`/support/${d.ticket.id}`)
    } catch (err) {
      const ex = err as ApiError
      setErrors(ex.details ?? { _form: ex.message })
    } finally { setBusy(false) }
  }

  const tickets = list.data.tickets
  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">1:1 문의</h1>
        {!writing && <button className="btn" onClick={() => setWriting(true)}>문의 남기기</button>}
      </header>

      {writing && (
        <form className="panel form" onSubmit={submit} noValidate>
          <h2>새 문의</h2>
          <label>문의 유형
            <select value={form.category} onChange={set('category')}>
              {(cats.data?.categories ?? []).map((c) => <option key={c.code} value={c.code}>{c.label}</option>)}
            </select>
          </label>
          <label>제목
            <input maxLength={120} value={form.title} onChange={set('title')} aria-invalid={!!errors.title} />
            {errors.title && <span className="field-error">{errors.title}</span>}
          </label>
          <label>내용
            <textarea rows={6} maxLength={3000} value={form.content} onChange={set('content')} aria-invalid={!!errors.content} />
            {errors.content && <span className="field-error">{errors.content}</span>}
          </label>
          <p className="muted">주민등록번호·카드번호 같은 민감한 정보는 적지 마세요.</p>
          {errors._form && <p className="form-error">{errors._form}</p>}
          <div className="row">
            <button className="btn" disabled={busy}>등록</button>
            <button type="button" className="btn btn--ghost" onClick={() => setWriting(false)}>취소</button>
          </div>
        </form>
      )}

      {tickets.length === 0 ? (
        <div className="panel panel--muted"><p className="muted">아직 남긴 문의가 없습니다.</p></div>
      ) : (
        <ul className="rows">
          {tickets.map((t) => (
            <li key={t.id}>
              <Link to={`/support/${t.id}`} className="rows__item">
                <span className="rows__main">{t.title}</span>
                <span className="muted">{dateTime(t.created_at)}</span>
                <Tag tone={ticketTone(t.status)}>{TICKET_STATUS[t.status]}</Tag>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
