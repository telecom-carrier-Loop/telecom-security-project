import { useState, type FormEvent } from 'react'
import { Link } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag, { type Tone } from '../../components/common/Tag'
import { ApiError, api } from '../../services/apiClient'
import type { AccountStatus, CustomerRow } from '../../services/types'
import { compactDateTime, won } from '../../utils/format'
import { useApi } from '../../utils/useApi'

const STATUS: Record<AccountStatus, [string, Tone]> = {
  ACTIVE: ['정상', 'ok'], LOCKED: ['잠김', 'danger'], DEACTIVATED: ['탈퇴', 'neutral'],
}
const FILTERS: [string, string][] = [['', '전체'], ['ACTIVE', '정상'], ['LOCKED', '잠김'], ['DEACTIVATED', '탈퇴']]

// 회원 목록 + 계정 보안. 목록은 이메일을 가리고, 상세를 열 때만 전체를 보여준다 (열람은 서버 로그에 남음).
export default function AdminCustomersPage() {
  const [query, setQuery] = useState('')
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState('')
  const [page, setPage] = useState(1)
  const [selected, setSelected] = useState<number[]>([])
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const qs = new URLSearchParams({ page: String(page), ...(search ? { q: search } : {}), ...(status ? { status } : {}) }).toString()
  const { loading, error, data, reload } = useApi<{ customers: CustomerRow[]; page: number; size: number; total: number }>(`/admin/customers?${qs}`)

  const submit = (e: FormEvent) => { e.preventDefault(); setPage(1); setSearch(query.trim()) }
  const pages = data ? Math.max(Math.ceil(data.total / data.size), 1) : 1
  const toggle = (id: number) => setSelected((s) => (s.includes(id) ? s.filter((x) => x !== id) : [...s, id]))
  const selectable = (data?.customers ?? []).filter((c) => c.status !== 'DEACTIVATED')

  const run = async (fn: () => Promise<unknown>, okText: string) => {
    setMsg(null)
    try { await fn(); setMsg({ ok: true, text: okText }); setSelected([]); reload() }
    catch (err) { setMsg({ ok: false, text: (err as ApiError).message }) }
  }
  const lock = (c: CustomerRow) => {
    const reason = window.prompt(`${c.name}님 계정을 잠급니다. 사유를 입력하세요.`, '관리자 잠금')
    if (reason !== null) run(() => api(`/admin/customers/${c.id}/lock`, { method: 'POST', body: { reason } }), '계정을 잠갔습니다. 로그인 중이던 세션도 끊었습니다.')
  }
  const unlock = (c: CustomerRow) => run(() => api(`/admin/customers/${c.id}/unlock`, { method: 'POST' }), '잠금을 해제했습니다.')
  const deactivate = (c: CustomerRow) => {
    const reason = window.prompt(`${c.name}님을 탈퇴 처리합니다. 기록은 보존되고 다시 로그인할 수 없습니다. 사유를 입력하세요.`)
    if (reason) run(() => api(`/admin/customers/${c.id}/deactivate`, { method: 'POST', body: { reason } }), '탈퇴 처리했습니다.')
  }
  const bulk = (action: 'lock' | 'unlock') => {
    const reason = action === 'lock' ? window.prompt(`${selected.length}명을 잠급니다. 사유를 입력하세요.`, '관리자 일괄 잠금') : ''
    if (reason === null) return
    run(() => api('/admin/customers/bulk', { method: 'POST', body: { action, ids: selected, reason } }),
      action === 'lock' ? '선택한 회원을 잠갔습니다.' : '선택한 회원의 잠금을 해제했습니다.')
  }

  return (
    <section className="page page--wide">
      <h1 className="page__title">회원 목록 · 계정 보안</h1>
      <form className="searchbar" onSubmit={submit} role="search">
        <input type="search" placeholder="이름 또는 이메일로 검색" value={query} onChange={(e) => setQuery(e.target.value)} />
        <button className="btn">검색</button>
        {search && <button type="button" className="btn btn--ghost" onClick={() => { setQuery(''); setSearch(''); setPage(1) }}>초기화</button>}
      </form>
      <div className="filters">
        {FILTERS.map(([v, l]) => (
          <button key={v} className={`chip ${status === v ? 'chip--on' : ''}`} onClick={() => { setStatus(v); setPage(1); setSelected([]) }}>{l}</button>
        ))}
        <span className="filters__spacer" />
        <button className="btn btn--sm btn--danger" disabled={!selected.length} onClick={() => bulk('lock')}>선택 잠금 ({selected.length})</button>
        <button className="btn btn--sm btn--ghost" disabled={!selected.length} onClick={() => bulk('unlock')}>선택 해제 ({selected.length})</button>
      </div>
      {msg && <div className={`notice ${msg.ok ? 'notice--ok' : 'notice--warn'}`} role="status">{msg.text}</div>}

      {loading ? <Loading /> : error || !data ? <ErrorState error={error} onRetry={reload} /> : (
        <>
          <p className="muted">총 {data.total.toLocaleString()}명{search && ` · "${search}" 검색 결과`} · 잠긴 계정은 로그인과 기존 세션이 모두 거부됩니다. 가입일·청구 내역은 이름을 눌러 상세에서 확인하세요.</p>
          {data.customers.length === 0 ? <div className="panel panel--muted"><p className="muted">해당하는 회원이 없습니다.</p></div> : (
            <div className="table-wrap">
              <table className="table table--compact">
                <thead><tr>
                  <th><input type="checkbox" aria-label="전체 선택" checked={selectable.length > 0 && selected.length === selectable.length}
                             onChange={(e) => setSelected(e.target.checked ? selectable.map((c) => c.id) : [])} /></th>
                  <th>이름</th><th>이메일</th><th>상태</th><th className="num">15분 로그인 실패</th><th>잠금 시각</th><th>잠금 사유</th>
                  <th>요금제</th><th className="num">미납</th><th>동작</th>
                </tr></thead>
                <tbody>
                  {data.customers.map((c) => (
                    <tr key={c.id} className={c.status === 'LOCKED' ? 'row--locked' : ''}>
                      <td><input type="checkbox" aria-label={`${c.name} 선택`} disabled={c.status === 'DEACTIVATED'}
                                 checked={selected.includes(c.id)} onChange={() => toggle(c.id)} /></td>
                      <td><Link to={`/admin/customers/${c.id}`}>{c.name}</Link></td>
                      <td className="mono">{c.email}</td>
                      <td><Tag tone={STATUS[c.status][1]}>{STATUS[c.status][0]}</Tag></td>
                      <td className={`num ${c.login_failures_15m ? 'minus' : ''}`}>{c.login_failures_15m}</td>
                      <td>{c.locked_at ? compactDateTime(c.locked_at) : '-'}</td>
                      <td className="wrap">{c.lock_reason ?? '-'}</td>
                      <td>{c.plan ?? <span className="muted">없음</span>}</td>
                      <td className="num">{c.unpaid_amount ? won(c.unpaid_amount) : '-'}</td>
                      <td><div className="row">
                        {c.status === 'ACTIVE' && <button className="btn btn--sm btn--ghost" onClick={() => lock(c)}>잠금</button>}
                        {c.status === 'LOCKED' && <button className="btn btn--sm" onClick={() => unlock(c)}>해제</button>}
                        {c.status !== 'DEACTIVATED' && <button className="btn btn--sm btn--ghost" onClick={() => deactivate(c)}>탈퇴 처리</button>}
                      </div></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          {pages > 1 && (
            <div className="row pager">
              <button className="btn btn--ghost btn--sm" disabled={page <= 1} onClick={() => setPage(page - 1)}>이전</button>
              <span className="muted">{page} / {pages}</span>
              <button className="btn btn--ghost btn--sm" disabled={page >= pages} onClick={() => setPage(page + 1)}>다음</button>
            </div>
          )}
        </>
      )}
    </section>
  )
}
