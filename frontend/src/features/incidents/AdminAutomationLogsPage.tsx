import { useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag, { type Tone } from '../../components/common/Tag'
import { ApiError, api } from '../../services/apiClient'
import type { AutomationLog } from '../../services/types'
import { compactDateTime } from '../../utils/format'
import { useApi } from '../../utils/useApi'

const RESULT: Record<string, [string, Tone]> = {
  DONE: ['처리', 'ok'], ALREADY: ['이미 처리됨', 'neutral'], SKIPPED: ['건너뜀', 'warn'],
}

// 대상 표시: 인시던트는 상세로, 회원은 회원 상세로 이동
function Target({ log }: { log: AutomationLog }) {
  if (log.target_type === 'incident') return <Link to={`/admin/incidents/${log.target}`}>인시던트 #{log.target}</Link>
  if (log.target_type === 'user' && /^\d+$/.test(log.target)) return <Link to={`/admin/customers/${log.target}`}>회원 #{log.target}</Link>
  return <span className="mono">{log.target}</span>
}

// 자동화 기록 보기·삭제. 기록만 지우고, 이미 처리된 차단·잠금·인시던트는 각 화면에서 해제·종료한다.
export default function AdminAutomationLogsPage() {
  const { workflow = '' } = useParams()
  const [page, setPage] = useState(1)
  const [selected, setSelected] = useState<number[]>([])
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const { loading, error, data, reload } = useApi<{ name: string; logs: AutomationLog[]; total: number; size: number }>(
    `/admin/automation-logs?workflow=${encodeURIComponent(workflow)}&page=${page}`)

  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} onRetry={reload} />
  const pages = Math.max(Math.ceil(data.total / data.size), 1)
  const ids = data.logs.map((l) => l.id)

  const remove = async (body: Record<string, unknown>, label: string) => {
    const reason = window.prompt(`${label}을(를) 삭제합니다. 기록만 지워지고 차단·잠금·인시던트는 그대로 남습니다.\n삭제 사유를 입력하세요.`, '시험 기록 정리')
    if (reason === null) return
    try {
      const d = await api<{ deleted: number }>('/admin/automation-logs/delete', { method: 'POST', body: { ...body, reason } })
      setMsg({ ok: true, text: `${d.deleted}건 삭제했습니다.` }); setSelected([]); setPage(1); reload()
    } catch (err) { setMsg({ ok: false, text: (err as ApiError).message }) }
  }

  return (
    <section className="page page--wide">
      <Link to="/admin/automation" className="back">← 자동화 현황</Link>
      <header className="page__header">
        <h1 className="page__title">{data.name} 기록</h1>
        <span className="muted">총 {data.total}건</span>
      </header>
      {workflow === 'unknown' && (
        <div className="notice notice--warn">
          X-Workflow 헤더 없이 들어온 요청입니다. 토큰은 맞았지만 어느 워크플로인지 알 수 없어요. Postman이나 n8n 노드에 <span className="mono">X-Workflow: 4-ip-block</span>처럼 이름을 넣으면 해당 카드로 집계됩니다.
        </div>
      )}
      {msg && <div className={`notice ${msg.ok ? 'notice--ok' : 'notice--warn'}`} role="status">{msg.text}</div>}

      <div className="filters">
        <span className="filters__spacer" />
        <button className="btn btn--sm btn--ghost" disabled={!selected.length}
                onClick={() => remove({ ids: selected }, `선택한 기록 ${selected.length}건`)}>선택 삭제 ({selected.length})</button>
        <button className="btn btn--sm btn--danger" disabled={!data.total}
                onClick={() => remove({ workflow, all: true }, `${data.name} 기록 전체 ${data.total}건`)}>전체 삭제</button>
      </div>

      <div className="table-wrap">
        <table className="table table--compact">
          <thead><tr>
            <th><input type="checkbox" aria-label="전체 선택" checked={ids.length > 0 && selected.length === ids.length}
                       onChange={(e) => setSelected(e.target.checked ? ids : [])} /></th>
            <th>시각</th><th>처리</th><th>대상</th><th>결과</th><th>사유</th>
          </tr></thead>
          <tbody>
            {data.logs.length === 0 && <tr><td colSpan={6} className="muted">기록이 없습니다.</td></tr>}
            {data.logs.map((l) => (
              <tr key={l.id}>
                <td><input type="checkbox" aria-label={`${l.id} 선택`} checked={selected.includes(l.id)}
                           onChange={() => setSelected((s) => (s.includes(l.id) ? s.filter((x) => x !== l.id) : [...s, l.id]))} /></td>
                <td>{compactDateTime(l.created_at)}</td>
                <td>{l.action_label}</td>
                <td><Target log={l} /></td>
                <td><Tag tone={(RESULT[l.result] ?? [l.result, 'neutral'])[1]}>{(RESULT[l.result] ?? [l.result])[0]}</Tag></td>
                <td className="wrap">{l.reason ?? '-'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {pages > 1 && (
        <div className="row pager">
          <button className="btn btn--ghost btn--sm" disabled={page <= 1} onClick={() => { setPage(page - 1); setSelected([]) }}>이전</button>
          <span className="muted">{page} / {pages}</span>
          <button className="btn btn--ghost btn--sm" disabled={page >= pages} onClick={() => { setPage(page + 1); setSelected([]) }}>다음</button>
        </div>
      )}
      <p className="muted">삭제한 사실은 관리자 작업 기록으로 남고, 그 기록은 지울 수 없습니다.</p>
    </section>
  )
}
