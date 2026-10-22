import { useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag, { type Tone } from '../../components/common/Tag'
import type { Notice } from '../../services/types'
import { fullDate } from '../../utils/format'
import { useApi } from '../../utils/useApi'

export const NOTICE_TONE: Record<string, Tone> = { SECURITY: 'danger', MAINTENANCE: 'warn', EVENT: 'ok', GENERAL: 'neutral' }

// 공지사항 목록
export default function NoticesPage() {
  const [category, setCategory] = useState('')
  const [page, setPage] = useState(1)
  const qs = new URLSearchParams({ page: String(page), ...(category ? { category } : {}) }).toString()
  const { loading, error, data, reload } = useApi<{ notices: Notice[]; total: number; size: number; categories: { code: string; label: string }[] }>(`/notices?${qs}`)
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} onRetry={reload} />
  const pages = Math.max(Math.ceil(data.total / data.size), 1)
  return (
    <section className="page">
      <h1 className="page__title">공지사항</h1>
      <div className="filters">
        {[{ code: '', label: '전체' }, ...data.categories].map((c) => (
          <button key={c.code} className={`chip ${category === c.code ? 'chip--on' : ''}`} aria-pressed={category === c.code}
                  onClick={() => { setCategory(c.code); setPage(1) }}>{c.label}</button>
        ))}
      </div>
      {data.notices.length === 0 ? <div className="panel panel--muted"><p className="muted">공지사항이 없습니다.</p></div> : (
        <ul className="notice-list">
          {data.notices.map((n) => (
            <li key={n.id} className={n.is_pinned ? 'notice-list__item notice-list__item--pinned' : 'notice-list__item'}>
              <Link to={`/notices/${n.id}`}>
                <span className="row">
                  {n.is_pinned && <Tag tone="info">중요</Tag>}
                  <Tag tone={NOTICE_TONE[n.category]}>{n.category_label}</Tag>
                  <strong>{n.title}</strong>
                </span>
                <span className="muted">{n.summary}</span>
                <span className="muted">{fullDate(n.published_at)} · 조회 {n.view_count}</span>
              </Link>
            </li>
          ))}
        </ul>
      )}
      {pages > 1 && (
        <div className="row pager">
          <button className="btn btn--ghost btn--sm" disabled={page <= 1} onClick={() => setPage(page - 1)}>이전</button>
          <span className="muted">{page} / {pages}</span>
          <button className="btn btn--ghost btn--sm" disabled={page >= pages} onClick={() => setPage(page + 1)}>다음</button>
        </div>
      )}
    </section>
  )
}

// 공지사항 상세 — 본문은 글자 그대로 보여준다 (HTML 로 해석하지 않음)
export function NoticeDetailPage() {
  const { id } = useParams()
  const { loading, error, data, reload } = useApi<{ notice: Notice }>(`/notices/${id}`)
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} onRetry={reload} />
  const n = data.notice
  return (
    <section className="page">
      <Link to="/notices" className="back">← 공지사항</Link>
      <article className="panel notice-detail">
        <header className="row"><Tag tone={NOTICE_TONE[n.category]}>{n.category_label}</Tag><span className="muted">{fullDate(n.published_at)} · 조회 {n.view_count}</span></header>
        <h1 className="page__title">{n.title}</h1>
        <p className="notice-detail__body">{n.content}</p>
      </article>
    </section>
  )
}
