import { useState } from 'react'
import { Link } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag, { SeverityTag, incidentTone } from '../../components/common/Tag'
import type { Incident } from '../../services/types'
import { INCIDENT_STATUS, SEVERITY_LABEL, compactDateTime } from '../../utils/format'
import { useApi } from '../../utils/useApi'
import { deleteIncidents } from './deleteIncidents'

const STATUS_FILTERS = [['ACTIVE', '미해결'], ['', '전체'], ['OPEN', '신규'], ['INVESTIGATING', '조사 중'], ['RESOLVED', '해결'], ['CLOSED', '종료']]
const isOpen = (i: Incident) => i.status === 'OPEN' || i.status === 'INVESTIGATING'

export default function AdminIncidentsPage() {
  const [status, setStatus] = useState('ACTIVE')
  const [severity, setSeverity] = useState('')
  const [selected, setSelected] = useState<number[]>([])
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const qs = new URLSearchParams(Object.entries({ status, severity }).filter(([, v]) => v)).toString()
  const { loading, error, data, reload } = useApi<{ incidents: Incident[] }>(`/admin/incidents${qs ? `?${qs}` : ''}`)
  const rows = data?.incidents ?? []

  const remove = async () => {
    const openCount = rows.filter((i) => selected.includes(i.id) && isOpen(i)).length
    const result = await deleteIncidents(selected, openCount)
    if (!result) return
    setMsg(result)
    if (result.ok) { setSelected([]); reload() }
  }
  const change = (fn: () => void) => { fn(); setSelected([]); setMsg(null) }

  return (
    <section className="page page--wide">
      <h1 className="page__title">보안 인시던트</h1>
      <div className="filters">
        {STATUS_FILTERS.map(([v, l]) => (
          <button key={v} className={`chip ${status === v ? 'chip--on' : ''}`} aria-pressed={status === v}
                  onClick={() => change(() => setStatus(v))}>{l}</button>
        ))}
        <select value={severity} onChange={(e) => change(() => setSeverity(e.target.value))} aria-label="심각도">
          <option value="">모든 심각도</option>
          {Object.entries(SEVERITY_LABEL).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
        </select>
        <span className="filters__spacer" />
        <button className="btn btn--sm btn--ghost" disabled={!selected.length} onClick={remove}>선택 삭제 ({selected.length})</button>
      </div>
      {msg && <div className={`notice ${msg.ok ? 'notice--ok' : 'notice--warn'}`} role="status">{msg.text}</div>}

      {loading ? <Loading /> : error || !data ? <ErrorState error={error} onRetry={reload} /> : (
        rows.length === 0 ? <div className="panel panel--muted"><p className="muted">해당하는 인시던트가 없습니다.</p></div> : (
          <div className="table-wrap">
            <table className="table table--compact">
              <thead><tr>
                <th><input type="checkbox" aria-label="전체 선택" checked={selected.length === rows.length}
                           onChange={(e) => setSelected(e.target.checked ? rows.map((i) => i.id) : [])} /></th>
                <th>심각도</th><th>제목</th><th>출처</th><th>탐지 시각</th><th>담당</th><th>상태</th>
              </tr></thead>
              <tbody>
                {rows.map((i) => (
                  <tr key={i.id}>
                    <td><input type="checkbox" aria-label={`${i.title} 선택`} checked={selected.includes(i.id)}
                               onChange={() => setSelected((s) => (s.includes(i.id) ? s.filter((x) => x !== i.id) : [...s, i.id]))} /></td>
                    <td><SeverityTag severity={i.severity} /></td>
                    <td className="wrap"><Link to={`/admin/incidents/${i.id}`}>{i.title}</Link><div className="muted mono">{i.event_type}</div></td>
                    <td>{i.source}</td><td>{compactDateTime(i.detected_at)}</td>
                    <td>{i.assigned_to?.name ?? <span className="muted">미배정</span>}</td>
                    <td><Tag tone={incidentTone(i.status)}>{INCIDENT_STATUS[i.status]}</Tag></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )
      )}
      <p className="muted">기본은 해결·종료된 인시던트만 삭제됩니다. 신규·조사 중인 것이 섞여 있으면 한 번 더 확인합니다. 차단·잠금 같은 조치는 삭제해도 그대로 남습니다.</p>
    </section>
  )
}
