import { useState, type FormEvent } from 'react'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag from '../../components/common/Tag'
import { ApiError, api } from '../../services/apiClient'
import type { IpBlock, WhitelistEntry } from '../../services/types'
import { compactDateTime, dateTime } from '../../utils/format'
import { useApi } from '../../utils/useApi'

const MINUTES: [string, string][] = [['30', '30분'], ['60', '1시간'], ['360', '6시간'], ['1440', '1일'], ['10080', '7일'], ['', '영구']]
const FW: Record<string, string> = { SKIPPED: '미연동', PENDING: '대기', SYNCED: '반영됨', FAILED: '실패' }
type Msg = { ok: boolean; text: string } | null
const RESULT: Record<string, string> = { CREATED: '차단', ALREADY: '이미 차단됨', WHITELISTED: '화이트리스트라 제외', SELF: '내 IP라 제외' }

// 차단 IP 목록 + 화이트리스트 (관리자 전용). 해제 예정 시각은 여기서만 보이고, 차단된 사용자에게는 알려주지 않는다.
export default function AdminIpBlocksPage() {
  const [status, setStatus] = useState<'active' | 'all'>('active')
  const [query, setQuery] = useState('')
  const [search, setSearch] = useState('')
  const [page, setPage] = useState(1)
  const qs = new URLSearchParams({ status, page: String(page), ...(search ? { q: search } : {}) }).toString()
  const blocks = useApi<{ blocks: IpBlock[]; total: number; size: number; my_ip: string }>(`/admin/ip-blocks?${qs}`)
  const white = useApi<{ whitelist: WhitelistEntry[]; my_ip: string }>('/admin/ip-whitelist')
  const [form, setForm] = useState({ ips: '', reason: '', minutes: '60' })
  const [wForm, setWForm] = useState({ cidr: '', memo: '' })
  const [selected, setSelected] = useState<number[]>([])
  const [msg, setMsg] = useState<Msg>(null)

  if (blocks.loading || white.loading) return <Loading />
  if (blocks.error || !blocks.data) return <ErrorState error={blocks.error} onRetry={blocks.reload} />
  const reloadAll = () => { blocks.reload(); white.reload() }
  const fail = (err: unknown) => {
    const ex = err as ApiError
    setMsg({ ok: false, text: ex.details ? Object.values(ex.details).join(' ') : ex.message })
  }

  const add = async (e: FormEvent) => {
    e.preventDefault(); setMsg(null)
    try {
      const d = await api<{ results: { ip: string; result: string }[] }>('/admin/ip-blocks', {
        method: 'POST', body: { ips: form.ips, reason: form.reason, minutes: form.minutes ? Number(form.minutes) : null },
      })
      setMsg({ ok: true, text: d.results.map((r) => `${r.ip}: ${RESULT[r.result] ?? r.result}`).join(' · ') })
      setForm({ ...form, ips: '', reason: '' }); reloadAll()
    } catch (err) { fail(err) }
  }
  const release = async (ids: number[]) => {
    if (!ids.length || !window.confirm(`${ids.length}건의 차단을 해제할까요?`)) return
    try {
      const d = await api<{ released: number }>('/admin/ip-blocks/release', { method: 'POST', body: { ids } })
      setMsg({ ok: true, text: `${d.released}건 해제했습니다.` }); setSelected([]); reloadAll()
    } catch (err) { fail(err) }
  }
  const addWhite = async (e: FormEvent) => {
    e.preventDefault(); setMsg(null)
    try { await api('/admin/ip-whitelist', { method: 'POST', body: wForm }); setWForm({ cidr: '', memo: '' }); setMsg({ ok: true, text: '화이트리스트에 추가했습니다. 이 주소의 현재 차단도 함께 풀었습니다.' }); reloadAll() }
    catch (err) { fail(err) }
  }
  const delWhite = async (w: WhitelistEntry) => {
    if (!window.confirm(`${w.cidr} 를 화이트리스트에서 뺄까요?`)) return
    try { await api(`/admin/ip-whitelist/${w.id}`, { method: 'DELETE' }); reloadAll() } catch (err) { fail(err) }
  }

  const rows = blocks.data.blocks
  const active = rows.filter((b) => b.status === 'ACTIVE')
  const pages = Math.max(Math.ceil(blocks.data.total / blocks.data.size), 1)
  return (
    <section className="page page--wide">
      <h1 className="page__title">차단 IP 목록</h1>
      <p className="muted page__lead">차단된 IP의 요청은 앱에 닿기 전에 403으로 거부됩니다. 해제 예정 시각은 관리자에게만 보입니다. 내 IP {blocks.data.my_ip}</p>
      {msg && <div className={`notice ${msg.ok ? 'notice--ok' : 'notice--warn'}`} role="status">{msg.text}</div>}

      <form className="panel inline-form" onSubmit={add}>
        <input className="grow" placeholder="차단할 IP — 여러 개는 쉼표로 (예: 203.0.113.5, 198.51.100.7)" value={form.ips} onChange={(e) => setForm({ ...form, ips: e.target.value })} />
        <input placeholder="사유 (선택)" value={form.reason} onChange={(e) => setForm({ ...form, reason: e.target.value })} />
        <select value={form.minutes} onChange={(e) => setForm({ ...form, minutes: e.target.value })} aria-label="차단 시간">
          {MINUTES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
        </select>
        <button className="btn btn--danger" disabled={!form.ips.trim()}>차단 추가</button>
      </form>

      <div className="filters">
        {(['active', 'all'] as const).map((s) => (
          <button key={s} className={`chip ${status === s ? 'chip--on' : ''}`} onClick={() => { setStatus(s); setPage(1); setSelected([]) }}>
            {s === 'active' ? '차단 중' : '전체 기록'}
          </button>
        ))}
        <form className="row" onSubmit={(e) => { e.preventDefault(); setPage(1); setSearch(query.trim()) }}>
          <input type="search" placeholder="IP·사유·워크플로 검색" value={query} onChange={(e) => setQuery(e.target.value)} />
          <button className="btn btn--sm">검색</button>
        </form>
        <span className="filters__spacer" />
        <button className="btn btn--sm btn--ghost" disabled={!selected.length} onClick={() => release(selected)}>선택 해제 ({selected.length})</button>
      </div>

      <div className="table-wrap">
        <table className="table table--compact">
          <thead><tr>
            <th><input type="checkbox" aria-label="전체 선택" checked={active.length > 0 && selected.length === active.length}
                       onChange={(e) => setSelected(e.target.checked ? active.map((b) => b.id) : [])} /></th>
            <th>IP</th><th>사유</th><th>출처</th><th>차단 시각</th><th>해제 예정</th><th className="num">재접근</th><th>방화벽</th><th>상태</th><th />
          </tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={10} className="muted">차단된 IP가 없습니다.</td></tr>}
            {rows.map((b) => (
              <tr key={b.id}>
                <td><input type="checkbox" disabled={b.status !== 'ACTIVE'} checked={selected.includes(b.id)} aria-label={`${b.ip} 선택`}
                           onChange={() => setSelected((s) => (s.includes(b.id) ? s.filter((x) => x !== b.id) : [...s, b.id]))} /></td>
                <td className="mono">{b.ip}</td>
                <td className="wrap">{b.reason}</td>
                <td>{b.source === 'MANUAL' ? '수동' : <span>자동화<div className="muted mono">{b.workflow ?? '-'}</div></span>}</td>
                <td>{compactDateTime(b.created_at)}</td>
                <td>{b.expires_at ? compactDateTime(b.expires_at) : '영구'}</td>
                <td className="num">{b.hit_count}</td>
                <td><span className="muted" title="방화벽(pfSense) 연동은 나중에 붙일 예정">{FW[b.firewall_status]}</span></td>
                <td><Tag tone={b.status === 'ACTIVE' ? 'danger' : 'neutral'}>{b.status === 'ACTIVE' ? '차단 중' : b.status === 'EXPIRED' ? '만료' : '해제'}</Tag></td>
                <td>{b.status === 'ACTIVE' && <button className="btn btn--sm btn--ghost" onClick={() => release([b.id])}>해제</button>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {pages > 1 && (
        <div className="row pager">
          <button className="btn btn--ghost btn--sm" disabled={page <= 1} onClick={() => setPage(page - 1)}>이전</button>
          <span className="muted">{page} / {pages}</span>
          <button className="btn btn--ghost btn--sm" disabled={page >= pages} onClick={() => setPage(page + 1)}>다음</button>
        </div>
      )}

      <h2 className="section-title">화이트리스트</h2>
      <p className="muted">여기 있는 주소는 수동·자동 모두 차단되지 않습니다. 관리 PC, 게이트웨이, VPN 대역을 넣어 두세요.</p>
      <form className="panel inline-form" onSubmit={addWhite}>
        <input className="grow" placeholder="IP 또는 대역 (예: 192.168.50.0/24)" value={wForm.cidr} onChange={(e) => setWForm({ ...wForm, cidr: e.target.value })} />
        <input placeholder="메모 (예: 관리자 VPN)" value={wForm.memo} onChange={(e) => setWForm({ ...wForm, memo: e.target.value })} />
        <button type="button" className="btn btn--ghost" onClick={() => setWForm({ ...wForm, cidr: white.data?.my_ip ?? '' })}>내 IP 넣기</button>
        <button className="btn" disabled={!wForm.cidr.trim()}>추가</button>
      </form>
      <table className="table">
        <thead><tr><th>주소</th><th>메모</th><th>등록 시각</th><th /></tr></thead>
        <tbody>
          {(white.data?.whitelist ?? []).map((w) => (
            <tr key={w.id}><td className="mono">{w.cidr}</td><td>{w.memo ?? '-'}</td><td>{dateTime(w.created_at)}</td>
              <td><button className="btn btn--sm btn--ghost" onClick={() => delWhite(w)}>삭제</button></td></tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}
