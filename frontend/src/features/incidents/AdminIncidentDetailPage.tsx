import { useState, type FormEvent } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { deleteIncidents } from './deleteIncidents'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag, { SeverityTag, incidentTone } from '../../components/common/Tag'
import { ApiError, api } from '../../services/apiClient'
import type { IncidentDetail, IncidentStatus } from '../../services/types'
import { INCIDENT_STATUS, dateTime } from '../../utils/format'
import { useApi } from '../../utils/useApi'

// 서버 TRANSITIONS 와 같은 규칙 (버튼 표시용일 뿐, 실제 검증은 서버)
// OPEN → INVESTIGATING → RESOLVED → CLOSED, RESOLVED → INVESTIGATING 재개
const NEXT: Record<IncidentStatus, IncidentStatus[]> = {
  OPEN: ['INVESTIGATING'], INVESTIGATING: ['RESOLVED'], RESOLVED: ['CLOSED', 'INVESTIGATING'], CLOSED: [],
}
const NEXT_LABEL: Record<IncidentStatus, string> = {
  OPEN: '', INVESTIGATING: '조사 시작', RESOLVED: '해결 처리', CLOSED: '종료',
}
const ACTION: Record<string, string> = { CREATED: '생성', STATUS_CHANGED: '상태 변경', ASSIGNED: '담당 배정', NOTE: '대응 기록' }

export default function AdminIncidentDetailPage() {
  const { id } = useParams()
  const { loading, error, data, reload } = useApi<{ incident: IncidentDetail }>(`/admin/incidents/${id}`)
  const people = useApi<{ assignees: { id: number; name: string }[] }>('/admin/incidents/assignees')
  const [note, setNote] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const navigate = useNavigate()
  if (loading || people.loading) return <Loading />
  if (error || !data) return <ErrorState error={error} />
  const i = data.incident

  const patch = async (payload: Record<string, unknown>) => {
    setErr(null)
    try { await api(`/admin/incidents/${id}`, { method: 'PATCH', body: payload }); reload() }
    catch (ex) { setErr((ex as ApiError).message) }
  }
  const remove = async () => {
    const open = i.status === 'OPEN' || i.status === 'INVESTIGATING'
    const result = await deleteIncidents([i.id], open ? 1 : 0)
    if (!result) return
    if (result.ok) navigate('/admin/incidents', { replace: true })
    else setErr(result.text)
  }
  const addNote = async (e: FormEvent) => {
    e.preventDefault(); setErr(null)
    try { await api(`/admin/incidents/${id}/histories`, { method: 'POST', body: { note } }); setNote(''); reload() }
    catch (ex) { setErr((ex as ApiError).details?.note ?? (ex as ApiError).message) }
  }

  return (
    <section className="page">
      <Link to="/admin/incidents" className="back">← 인시던트 목록</Link>
      <header className="page__header">
        <h1 className="page__title">{i.title}</h1>
        <div className="row">
          <Tag tone={incidentTone(i.status)}>{INCIDENT_STATUS[i.status]}</Tag>
          <button className="btn btn--sm btn--ghost" onClick={remove}>삭제</button>
        </div>
      </header>
      {err && <div className="notice notice--warn" role="alert">{err}</div>}

      <div className="grid grid--usage">
        <article className="panel">
          <h2>탐지 정보</h2>
          <dl className="facts">
            <div><dt>심각도</dt><dd><SeverityTag severity={i.severity} /></dd></div>
            <div><dt>출처</dt><dd>{i.source}</dd></div>
            <div><dt>이벤트 종류</dt><dd className="mono">{i.event_type}</dd></div>
            <div><dt>원본 이벤트 ID</dt><dd className="mono">{i.event_id}</dd></div>
            <div><dt>대상</dt><dd>{[i.asset.host, i.asset.service].filter(Boolean).join(' / ') || '-'}</dd></div>
            <div><dt>탐지 시각</dt><dd>{dateTime(i.detected_at)}</dd></div>
            {i.scenario_id && <div><dt>시나리오</dt><dd className="mono">{i.scenario_id}</dd></div>}
            {i.request_id && <div><dt>요청 ID</dt><dd className="mono">{i.request_id}</dd></div>}
            <div><dt>해결 시각</dt><dd>{i.resolved_at ? dateTime(i.resolved_at) : '-'}</dd></div>
          </dl>
          {i.description && <p className="prewrap">{i.description}</p>}
          {i.evidence && <pre className="evidence mono">{JSON.stringify(i.evidence, null, 2)}</pre>}
        </article>
        <article className="panel">
          <h2>처리</h2>
          <label>담당자
            <select value={i.assigned_to?.id ?? ''} onChange={(e) => patch({ assigned_to: e.target.value ? Number(e.target.value) : null })}>
              <option value="">미배정</option>
              {(people.data?.assignees ?? []).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
          </label>
          <div className="row wrap">
            {NEXT[i.status].map((s) => (
              <button key={s} className="btn btn--ghost btn--sm" onClick={() => patch({ status: s })}>
                {i.status === 'RESOLVED' && s === 'INVESTIGATING' ? '다시 조사' : NEXT_LABEL[s]}
              </button>
            ))}
            {NEXT[i.status].length === 0 && <span className="muted">종료된 인시던트입니다.</span>}
          </div>
        </article>
      </div>

      <article className="panel">
        <h2>대응 이력</h2>
        <ol className="timeline">
          {i.histories.map((h) => (
            <li key={h.id}>
              <span className="timeline__meta">{dateTime(h.at)} · {h.actor} · {ACTION[h.action] ?? h.action}</span>
              <span className="prewrap">{h.note}</span>
            </li>
          ))}
        </ol>
        {i.status !== 'CLOSED' && (
          <form className="form" onSubmit={addNote}>
            <textarea rows={3} placeholder="조치 내용 (예: C에게 출발지 IP 차단 요청)" value={note} onChange={(e) => setNote(e.target.value)} />
            <button className="btn" disabled={note.trim().length < 2}>기록 추가</button>
          </form>
        )}
      </article>
    </section>
  )
}
