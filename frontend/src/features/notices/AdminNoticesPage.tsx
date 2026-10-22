import { useState, type FormEvent } from 'react'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag from '../../components/common/Tag'
import { ApiError, api } from '../../services/apiClient'
import type { Notice, NoticeCategory } from '../../services/types'
import { compactDateTime } from '../../utils/format'
import { useApi } from '../../utils/useApi'
import { NOTICE_TONE } from './NoticesPage'

const CATS: [NoticeCategory, string][] = [['GENERAL', '일반'], ['MAINTENANCE', '점검'], ['EVENT', '이벤트'], ['SECURITY', '보안']]
const EMPTY = { title: '', content: '', category: 'GENERAL' as NoticeCategory, is_pinned: false, is_published: true }

// 공지사항 관리: 작성·수정·게시/비공개·고정·삭제
export default function AdminNoticesPage() {
  const { loading, error, data, reload } = useApi<{ notices: Notice[] }>('/admin/notices')
  const [form, setForm] = useState(EMPTY)
  const [editing, setEditing] = useState<number | null>(null)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} onRetry={reload} />

  const fail = (err: unknown) => { const e = err as ApiError; setMsg({ ok: false, text: e.details ? Object.values(e.details).join(' ') : e.message }) }
  const edit = async (n: Notice) => {
    const d = await api<{ notice: Notice }>(`/admin/notices/${n.id}`)
    setForm({ title: d.notice.title, content: d.notice.content ?? '', category: d.notice.category, is_pinned: d.notice.is_pinned, is_published: d.notice.is_published })
    setEditing(n.id); setMsg(null); window.scrollTo({ top: 0 })
  }
  const submit = async (e: FormEvent) => {
    e.preventDefault()
    try {
      if (editing) await api(`/admin/notices/${editing}`, { method: 'PATCH', body: form })
      else await api('/admin/notices', { method: 'POST', body: form })
      setMsg({ ok: true, text: editing ? '수정했습니다.' : '등록했습니다.' }); setForm(EMPTY); setEditing(null); reload()
    } catch (err) { fail(err) }
  }
  const toggle = async (n: Notice, key: 'is_pinned' | 'is_published') => {
    try { await api(`/admin/notices/${n.id}`, { method: 'PATCH', body: { [key]: !n[key] } }); reload() } catch (err) { fail(err) }
  }
  const remove = async (n: Notice) => {
    if (!window.confirm(`"${n.title}" 공지를 삭제할까요?`)) return
    try { await api(`/admin/notices/${n.id}`, { method: 'DELETE' }); reload(); setMsg({ ok: true, text: '삭제했습니다.' }) } catch (err) { fail(err) }
  }

  return (
    <section className="page page--wide">
      <h1 className="page__title">공지사항 관리</h1>
      {msg && <div className={`notice ${msg.ok ? 'notice--ok' : 'notice--warn'}`} role="status">{msg.text}</div>}
      <form className="panel form" onSubmit={submit}>
        <h2 className="panel__title">{editing ? '공지 수정' : '새 공지'}</h2>
        <div className="row">
          <label>분류
            <select value={form.category} onChange={(e) => setForm({ ...form, category: e.target.value as NoticeCategory })}>
              {CATS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
          </label>
          <label className="check"><input type="checkbox" checked={form.is_pinned} onChange={(e) => setForm({ ...form, is_pinned: e.target.checked })} /> 상단 고정</label>
          <label className="check"><input type="checkbox" checked={form.is_published} onChange={(e) => setForm({ ...form, is_published: e.target.checked })} /> 바로 게시</label>
        </div>
        <label>제목<input maxLength={120} value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} required /></label>
        <label>내용<textarea rows={6} maxLength={10000} value={form.content} onChange={(e) => setForm({ ...form, content: e.target.value })} required /></label>
        <p className="muted">내용은 글자 그대로 표시됩니다(HTML은 적용되지 않음).</p>
        <div className="row">
          <button className="btn">{editing ? '수정' : '등록'}</button>
          {editing && <button type="button" className="btn btn--ghost" onClick={() => { setEditing(null); setForm(EMPTY) }}>취소</button>}
        </div>
      </form>
      <div className="table-wrap">
        <table className="table table--compact">
          <thead><tr><th>분류</th><th>제목</th><th>상태</th><th>게시일</th><th className="num">조회</th><th>동작</th></tr></thead>
          <tbody>
            {data.notices.map((n) => (
              <tr key={n.id}>
                <td><Tag tone={NOTICE_TONE[n.category]}>{n.category_label}</Tag></td>
                <td className="wrap">{n.is_pinned && <Tag tone="info">고정</Tag>} {n.title}</td>
                <td><Tag tone={n.is_published ? 'ok' : 'neutral'}>{n.is_published ? '게시' : '비공개'}</Tag></td>
                <td>{n.published_at ? compactDateTime(n.published_at) : '-'}</td>
                <td className="num">{n.view_count}</td>
                <td><div className="row">
                  <button className="btn btn--sm btn--ghost" onClick={() => edit(n)}>수정</button>
                  <button className="btn btn--sm btn--ghost" onClick={() => toggle(n, 'is_published')}>{n.is_published ? '내리기' : '게시'}</button>
                  <button className="btn btn--sm btn--ghost" onClick={() => toggle(n, 'is_pinned')}>{n.is_pinned ? '고정 해제' : '고정'}</button>
                  <button className="btn btn--sm btn--ghost" onClick={() => remove(n)}>삭제</button>
                </div></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
