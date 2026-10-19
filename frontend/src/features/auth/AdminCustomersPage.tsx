import { useState, type FormEvent } from 'react'
import { Link } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag from '../../components/common/Tag'
import type { CustomerRow } from '../../services/types'
import { fullDate, won } from '../../utils/format'
import { useApi } from '../../utils/useApi'

// 회원 목록 (상담 관리자). 목록에서는 이메일을 가리고, 상세를 열 때만 전체를 보여준다 (열람은 서버 로그에 남음).
export default function AdminCustomersPage() {
  const [query, setQuery] = useState('')
  const [search, setSearch] = useState('')
  const [page, setPage] = useState(1)
  const qs = new URLSearchParams({ page: String(page), ...(search ? { q: search } : {}) }).toString()
  const { loading, error, data, reload } = useApi<{ customers: CustomerRow[]; page: number; size: number; total: number }>(`/admin/customers?${qs}`)

  const submit = (e: FormEvent) => { e.preventDefault(); setPage(1); setSearch(query.trim()) }
  const pages = data ? Math.max(Math.ceil(data.total / data.size), 1) : 1

  return (
    <section className="page page--wide">
      <h1 className="page__title">회원 목록</h1>
      <form className="searchbar" onSubmit={submit} role="search">
        <input type="search" placeholder="이름 또는 이메일로 검색" value={query} onChange={(e) => setQuery(e.target.value)} />
        <button className="btn">검색</button>
        {search && <button type="button" className="btn btn--ghost" onClick={() => { setQuery(''); setSearch(''); setPage(1) }}>초기화</button>}
      </form>

      {loading ? <Loading /> : error || !data ? <ErrorState error={error} onRetry={reload} /> : (
        <>
          <p className="muted">총 {data.total.toLocaleString()}명{search && ` · "${search}" 검색 결과`}</p>
          {data.customers.length === 0 ? <div className="panel panel--muted"><p className="muted">해당하는 회원이 없습니다.</p></div> : (
            <table className="table table--click">
              <thead><tr><th>이름</th><th>이메일</th><th>요금제</th><th>멤버십</th><th className="num">미납</th><th>진행 중 문의</th><th>가입일</th><th>상태</th></tr></thead>
              <tbody>
                {data.customers.map((c) => (
                  <tr key={c.id}>
                    <td><Link to={`/admin/customers/${c.id}`}>{c.name}</Link></td>
                    <td className="mono">{c.email}</td>
                    <td>{c.plan ?? <span className="muted">없음</span>}</td>
                    <td>{c.membership ?? <span className="muted">미가입</span>}</td>
                    <td className="num">{c.unpaid_amount ? won(c.unpaid_amount) : '-'}</td>
                    <td>{c.open_tickets ? `${c.open_tickets}건` : '-'}</td>
                    <td>{fullDate(c.created_at)}</td>
                    <td><Tag tone={c.is_active ? 'ok' : 'neutral'}>{c.is_active ? '이용 중' : '탈퇴'}</Tag></td>
                  </tr>
                ))}
              </tbody>
            </table>
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
