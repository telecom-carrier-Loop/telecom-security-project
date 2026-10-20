import type { MonitoringLink } from '../../services/types'
import { useApi } from '../../utils/useApi'

// 관제 도구(Wazuh·Graylog 등) 바로가기. 주소는 서버 환경변수에서 받아온다 (관리자 전용 API).
// variant="nav" → 사이드바, "cards" → 대시보드 카드
export default function MonitoringLinks({ variant }: { variant: 'nav' | 'cards' }) {
  const { data } = useApi<{ links: MonitoringLink[] }>('/admin/monitoring-links')
  const links = data?.links ?? []
  if (!links.length) return null

  if (variant === 'nav') {
    return (
      <div className="nav__group">
        <p className="nav__heading">관제 도구</p>
        {links.map((l) => (l.url ? (
          <a key={l.key} href={l.url} target="_blank" rel="noopener noreferrer" className="nav__link nav__external">
            {l.name}<span aria-hidden="true">↗</span>
          </a>
        ) : (
          <span key={l.key} className="nav__link nav__disabled" title={`${l.env} 환경변수를 설정하세요`}>{l.name} (주소 미설정)</span>
        )))}
      </div>
    )
  }

  return (
    <div className="tool-cards">
      {links.map((l) => (l.url ? (
        <a key={l.key} href={l.url} target="_blank" rel="noopener noreferrer" className="tool-card">
          <strong>{l.name} <span aria-hidden="true">↗</span></strong>
          <span className="muted">{l.description}</span>
          <span className="mono tool-card__url">{l.url}</span>
        </a>
      ) : (
        <div key={l.key} className="tool-card tool-card--off">
          <strong>{l.name}</strong>
          <span className="muted">{l.description}</span>
          <span className="mono tool-card__url">{l.env} 미설정</span>
        </div>
      )))}
    </div>
  )
}
