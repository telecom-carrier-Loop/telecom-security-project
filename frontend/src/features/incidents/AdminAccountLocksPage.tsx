import { useEffect, useState, type FormEvent } from 'react'
import { Link } from 'react-router-dom'
import BlockNavigation from '../../components/common/BlockNavigation'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import type { Role } from '../../services/types'
import { dateTime, ROLE_LABEL } from '../../utils/format'
import { useApi } from '../../utils/useApi'

type LockedAccount = { id: number; name: string; email: string; role: Role; locked_at: string; lock_reason: string | null }
type LockResponse = { accounts?: LockedAccount[]; customers?: Omit<LockedAccount, 'role'>[]; total: number; size: number }

export default function AdminAccountLocksPage() {
  const [query, setQuery] = useState('')
  const [search, setSearch] = useState('')
  const [page, setPage] = useState(1)
  const [legacy, setLegacy] = useState(false)
  const params = new URLSearchParams({ page: String(page), q: search })
  const path = legacy ? `/admin/customers?status=LOCKED&${params}` : `/admin/account-locks?${params}`
  const { data, loading, error, reload } = useApi<LockResponse>(path)
  // 신규 API가 없는 이전 개발 서버에서만 기존 관리자 전용 조회를 사용한다.
  useEffect(() => { if (error?.status === 404 && !legacy) setLegacy(true) }, [error, legacy])
  const accounts: LockedAccount[] = legacy
    ? (data?.customers ?? []).map(a => ({ ...a, role: 'CUSTOMER' }))
    : data?.accounts ?? []
  const submit = (e: FormEvent) => { e.preventDefault(); setPage(1); setSearch(query.trim()) }
  const pages = data ? Math.max(1, Math.ceil(data.total / data.size)) : 1
  return <section className="page page--wide">
    <header className="page__header"><h1 className="page__title">차단 계정</h1><button type="button" className="btn btn--ghost btn--sm" onClick={reload}>새로고침</button></header>
    <BlockNavigation />
    <p className="muted">현재 잠금 상태인 활성 계정입니다. IP 차단과는 별개이며, 탈퇴 계정은 제외합니다.</p>
    {legacy && <p className="notice notice--warn" role="status">이전 백엔드와 호환되는 고객 계정 목록으로 조회합니다. 관리자 계정까지 조회하려면 최신 백엔드를 재시작한 뒤 페이지를 새로고침하세요.</p>}
    <form className="searchbar" role="search" onSubmit={submit}><input type="search" aria-label="차단 계정 이름 또는 이메일" placeholder="이름 또는 이메일로 검색" value={query} onChange={e => setQuery(e.target.value)} /><button className="btn">검색</button>{search && <button type="button" className="btn btn--ghost" onClick={() => { setQuery(''); setSearch(''); setPage(1) }}>초기화</button>}</form>
    {loading ? <Loading /> : error || !data ? <ErrorState error={error} onRetry={reload} /> : <>
      <p className="muted">총 {data.total.toLocaleString()}개 계정</p>
      {!accounts.length ? <div className="panel panel--muted">차단된 {legacy ? '고객 ' : ''}계정이 없습니다.</div> : <div className="table-wrap"><table className="table"><thead><tr><th>이름</th><th>이메일</th><th>권한</th><th>잠금 시각</th><th>잠금 사유</th><th>회원 관리</th></tr></thead><tbody>{accounts.map(a => <tr key={a.id}><td>{a.name}</td><td>{a.email}</td><td>{ROLE_LABEL[a.role]}</td><td>{dateTime(a.locked_at)}</td><td className="prewrap">{a.lock_reason || '-'}</td><td>{a.role === 'CUSTOMER' ? <Link to="/admin/customers">잠금 관리</Link> : <span className="muted">관리자 계정</span>}</td></tr>)}</tbody></table></div>}
      {pages > 1 && <div className="row pager"><button className="btn btn--ghost btn--sm" disabled={page <= 1} onClick={() => setPage(page - 1)}>이전</button><span>{page} / {pages}</span><button className="btn btn--ghost btn--sm" disabled={page >= pages} onClick={() => setPage(page + 1)}>다음</button></div>}
    </>}
  </section>
}
