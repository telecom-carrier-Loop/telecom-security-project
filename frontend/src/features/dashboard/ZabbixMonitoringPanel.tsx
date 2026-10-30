import { useEffect } from 'react'
import { useApi } from '../../utils/useApi'

type Point = { t: number; v: number }
type Monitoring = {
  configured: boolean; connected: boolean; updated_at: string | null; message: string | null
  nodes?: { name: string; ip: string; status: 'ON' | 'OFF' | 'UNKNOWN'; checked_at: number | null; message: string | null }[]
  services: { name: string; status: 'UP' | 'DOWN' | 'UNKNOWN'; checked_at: number | null }[]
  metrics: Record<string, number | null>; history: Record<string, Point[]>
  problems: { name: string; severity: number; clock: number }[]
}

const metrics: [string, string, string][] = [
  ['cpu', 'CPU 사용률', '%'], ['ram', 'RAM 사용률', '%'],
  ['disk_c', 'C 드라이브', '%'],
]

function Sparkline({ points }: { points: Point[] }) {
  if (points.length < 2) return <span className="muted">추이 데이터 대기 중</span>
  const numbers = points.map(p => p.v)
  const min = Math.min(...numbers), max = Math.max(...numbers)
  const range = max - min || 1
  const coords = points.map((p, i) => `${(i / (points.length - 1)) * 100},${35 - ((p.v - min) / range) * 30}`).join(' ')
  return <svg viewBox="0 0 100 40" preserveAspectRatio="none" role="img" aria-label="최근 1시간 사용량 추이" style={{ width: '100%', height: 65 }}>
    <polyline points={coords} fill="none" stroke="var(--signal)" strokeWidth="1.6" vectorEffect="non-scaling-stroke" />
  </svg>
}

function pretty(value: number | null | undefined, unit: string) {
  if (value == null) return '수집 대기'
  return `${value.toFixed(1)}${unit}`
}

export default function ZabbixMonitoringPanel() {
  const { loading, error, data, reload } = useApi<Monitoring>('/admin/monitoring/zabbix')
  useEffect(() => {
    const timer = window.setInterval(reload, 30000)
    return () => window.clearInterval(timer)
  }, [reload])
  return <section className="zabbix-monitoring" aria-label="Zabbix 실시간 모니터링">
    <header className="panel__head zabbix-heading">
      <h2>Zabbix 인프라 모니터링</h2>
      <button type="button" className="btn btn--ghost btn--sm" onClick={reload}>새로고침</button>
    </header>
    {loading && <p className="muted">Zabbix 데이터를 불러오는 중…</p>}
    {error && <p role="alert" className="notice notice--warn">Zabbix 조회 요청에 실패했습니다: {error.message}</p>}
    {data && !data.connected && <p role="status" className="notice notice--warn">{data.message || 'Zabbix 연결 상태를 확인할 수 없습니다.'}</p>}
    {data?.connected && <>
      <p className="muted">{data.updated_at ? `마지막 조회: ${new Date(data.updated_at).toLocaleString('ko-KR')}` : '조회 시각 미제공'} · 30초마다 갱신 · 서비스별 측정 시각은 아래 표시</p>
      <h3>Kubernetes VM 연결 상태</h3>
      <p className="muted">ON은 네트워크 응답 확인, OFF는 Ping·SSH·등록 서비스 모두 응답 없음입니다. 전원 상태를 직접 측정하지 않으며, 방화벽·네트워크 장애도 OFF로 표시될 수 있습니다.</p>
      <div className="grid grid--2">
        {(data.nodes || []).map(node => <article className="tile" key={node.name}>
          <span className="tile__label">{node.name} · {node.ip}</span>
          <strong className="tile__value" style={{ color: node.status === 'ON' ? 'var(--ok)' : node.status === 'OFF' ? 'var(--danger)' : 'var(--ink-soft)' }}>
            {node.status === 'UNKNOWN' ? '확인 불가' : node.status}
          </strong>
          <span className="tile__sub">{node.message || 'ICMP / SSH / 서비스 TCP 응답 기준'}</span>
          <span className="tile__sub">마지막 측정 · {node.checked_at ? new Date(node.checked_at * 1000).toLocaleString('ko-KR') : '수집 대기'}</span>
        </article>)}
      </div>
      {data.services.some(s => s.status === 'DOWN') && <p className="notice notice--danger" role="status">TCP 연결 실패 {data.services.filter(s => s.status === 'DOWN').length}개 · 아래 서비스와 측정 시각을 확인하세요.</p>}
      <div className="grid grid--3">
        {data.services.map(service => <article key={service.name} className="tile">
          <span className="tile__label">{service.name}</span>
          <strong className="tile__value" style={{ color: service.status === 'UP' ? 'var(--ok)' : service.status === 'DOWN' ? 'var(--danger)' : 'var(--ink-soft)' }}>{service.status}</strong>
          <span className="tile__sub">TCP 연결 감시 · {service.checked_at ? new Date(service.checked_at * 1000).toLocaleTimeString('ko-KR') : '수집 대기'}</span>
        </article>)}
      </div>
      <div className="grid grid--3">
        {metrics.map(([key, label, unit]) => <article className="panel" key={key} style={{ minWidth: 0 }}>
          <span className="tile__label">PC2 Windows · {label}</span>
          <strong className="tile__value">{pretty(data.metrics[key], unit)}</strong>
          <Sparkline points={data.history[key] || []} />
        </article>)}
      </div>
      <article className="panel">
        <h2>활성 Zabbix 장애 · {data.problems.length}건{data.problems.length === 20 ? ' 이상' : ''}</h2>
        {data.problems.length ? <ul className="list">{data.problems.map((p, i) => <li key={i}><span>{p.name}</span><span className="muted">심각도 {p.severity} · {new Date(p.clock * 1000).toLocaleString('ko-KR')}</span></li>)}</ul> : <p className="muted">현재 조회된 활성 장애 없음</p>}
      </article>
    </>}
  </section>
}
