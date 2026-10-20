import { useState } from 'react'
import { Link } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag, { incidentTone, severityTone } from '../../components/common/Tag'
import { INCIDENT_STATUS, SEVERITY_LABEL, dateTime } from '../../utils/format'
import type { Incident } from '../../services/types'
import { useApi } from '../../utils/useApi'

const STATUS_FILTERS = [['ACTIVE', '미해결'], ['', '전체'], ['OPEN', '신규'], ['INVESTIGATING', '조사 중'], ['RESOLVED', '해결'], ['CLOSED', '종료']]

export default function AdminIncidentsPage() {
  const [status, setStatus] = useState('ACTIVE')
  const [severity, setSeverity] = useState('')
  const qs = new URLSearchParams(Object.entries({ status, severity }).filter(([, v]) => v)).toString()
  const { loading, error, data, reload } = useApi<{ incidents: Incident[] }>(`/admin/incidents${qs ? `?${qs}` : ''}`)

  return (
    <section className="page">
      <h1 className="page__title">보안 인시던트</h1>
      <div className="filters">
        {STATUS_FILTERS.map(([v, l]) => (
          <button key={v} className={`chip ${status === v ? 'chip--on' : ''}`} aria-pressed={status === v}
                  onClick={() => setStatus(v)}>{l}</button>
        ))}
        <select value={severity} onChange={(e) => setSeverity(e.target.value)} aria-label="심각도">
          <option value="">모든 심각도</option>
          {Object.entries(SEVERITY_LABEL).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
        </select>
      </div>
      {loading ? <Loading /> : error || !data ? <ErrorState error={error} onRetry={reload} /> : (
        data.incidents.length === 0 ? <div className="panel panel--muted"><p className="muted">해당하는 인시던트가 없습니다.</p></div> : (
          <table className="table">
            <thead><tr><th>심각도</th><th>제목</th><th>출처</th><th>탐지 시각</th><th>담당</th><th>상태</th></tr></thead>
            <tbody>
              {data.incidents.map((i) => (
                <tr key={i.id}>
                  <td><Tag tone={severityTone(i.severity)}>{SEVERITY_LABEL[i.severity]}</Tag></td>
                  <td><Link to={`/admin/incidents/${i.id}`}>{i.title}</Link><div className="muted mono">{i.event_type}</div></td>
                  <td>{i.source}</td><td>{dateTime(i.detected_at)}</td>
                  <td>{i.assigned_to?.name ?? <span className="muted">미배정</span>}</td>
                  <td><Tag tone={incidentTone(i.status)}>{INCIDENT_STATUS[i.status]}</Tag></td>
                </tr>
              ))}
            </tbody>
          </table>
        )
      )}
    </section>
  )
}
