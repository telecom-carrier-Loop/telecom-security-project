import { useState } from 'react'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import type { MonitoringLink } from '../../services/types'
import { useApi } from '../../utils/useApi'

// 관제 지표: Grafana 대시보드를 관리자 화면 안에 띄운다 (GRAFANA_EMBED_URL).
// Grafana 는 읽기 전용(grafana_ro) 데이터 소스만 쓰고, 이 화면 자체는 관리자 로그인 뒤에만 보인다.
export default function AdminGrafanaPage() {
  const { loading, error, data, reload } = useApi<{ links: MonitoringLink[]; grafana_embed_url: string | null }>('/admin/monitoring-links')
  const [key, setKey] = useState(0)
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} onRetry={reload} />
  const url = data.grafana_embed_url
  const grafana = data.links.find((l) => l.key === 'grafana')

  return (
    <section className="page page--wide grafana-page">
      <header className="page__header">
        <h1 className="page__title">관제 지표</h1>
        <div className="row">
          {url && <button className="btn btn--sm btn--ghost" onClick={() => setKey((k) => k + 1)}>새로고침</button>}
          {grafana?.url && <a className="btn btn--sm btn--ghost" href={grafana.url} target="_blank" rel="noopener noreferrer">Grafana에서 열기 ↗</a>}
        </div>
      </header>
      {!url ? (
        <div className="panel panel--muted">
          <h2>Grafana 대시보드 주소가 설정되지 않았습니다</h2>
          <p className="muted">서버 <span className="mono">.env</span>에 <span className="mono">GRAFANA_EMBED_URL</span>을 넣고 Flask를 다시 켜세요.</p>
          <p className="muted">값은 Grafana에서 대시보드를 연 상태의 주소창 주소입니다. 예: <span className="mono">http://localhost:3000/d/abc123/loop-security?orgId=1</span></p>
        </div>
      ) : (
        <iframe
          key={key}
          className="grafana-frame"
          src={url}
          title="L∞P 보안 관제 지표 (Grafana)"
          referrerPolicy="no-referrer"
          sandbox="allow-scripts allow-same-origin allow-popups"
        />
      )}
      <p className="muted">그래프가 비어 있거나 로그인 화면이 보이면 Grafana의 임베드 허용·익명 보기 설정을 확인하세요. 이 화면은 Grafana에 접속할 수 있는 PC에서만 보입니다.</p>
    </section>
  )
}
