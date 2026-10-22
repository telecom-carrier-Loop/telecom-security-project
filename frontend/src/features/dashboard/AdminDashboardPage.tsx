import { Link } from 'react-router-dom'
import { useAuth } from '../../app/providers/AuthProvider'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import { STATUS_LABEL, dateTime, won } from '../../utils/format'
import type { AdminDashboard, Severity, MonitoringLink } from '../../services/types'
import { useApi } from '../../utils/useApi'
import MonitoringLinks from '../../components/common/MonitoringLinks'

const SEVERITIES: [Severity, string][] = [
  ['critical', '긴급'], ['high', '높음'], ['medium', '보통'], ['low', '낮음'], ['info', '정보'],
]

// 운영 대시보드: 개인정보 목록이 아니라 '지금 처리할 일'의 숫자를 보여준다
export default function AdminDashboardPage() {
  const { user } = useAuth()
  const { loading, error, data, reload } = useApi<AdminDashboard>('/admin/dashboard')
  const mon = useApi<{ links: MonitoringLink[]; grafana_embed_url: string | null; grafana_panel_url: string | null }>('/admin/monitoring-links')
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} onRetry={reload} />
  const { customers, support, billing, incidents, protection } = data
  // 대시보드에는 그래프 하나(GRAFANA_PANEL_URL)만, 전체는 관제 지표 화면에서
  const embedUrl = mon.data?.grafana_panel_url ?? null

  return (
    <section className="page">
      <h1 className="page__title">운영 대시보드</h1>
      <p className="muted page__lead">{user?.name} · 기준 시각 {dateTime(new Date().toISOString())}</p>

      <div className="grid grid--4">
        <Link to="/admin/incidents" className="tile">
          <span className="tile__label">미해결 인시던트</span>
          <span className="tile__value">{incidents.open}건</span>
          <span className="tile__sub">긴급·높음 {incidents.by_severity.critical + incidents.by_severity.high}건</span>
        </Link>
        <Link to="/admin/support" className="tile">
          <span className="tile__label">답변 대기 문의</span>
          <span className="tile__value">{support.waiting}건</span>
          <span className="tile__sub">접수·처리 중</span>
        </Link>
        <Link to="/admin/customers" className="tile">
          <span className="tile__label">활성 고객</span>
          <span className="tile__value">{customers.active}명</span>
          <span className="tile__sub">7일 신규 {customers.new_7d}명 · 15분 로그인 실패 {customers.login_failures_15m}</span>
        </Link>
        <div className="tile">
          <span className="tile__label">미납 청구</span>
          <span className="tile__value">{billing.unpaid_count}건</span>
          <span className="tile__sub">{won(billing.unpaid_amount)}</span>
        </div>
      </div>

      <div className="grid grid--3">
        <Link to="/admin/ip-blocks" className="tile">
          <span className="tile__label">차단 중인 IP</span>
          <span className="tile__value">{protection.active_blocks}개</span>
          <span className="tile__sub">자동·수동 차단 포함</span>
        </Link>
        <Link to="/admin/customers" className="tile">
          <span className="tile__label">잠긴 계정</span>
          <span className="tile__value">{protection.locked_accounts}개</span>
          <span className="tile__sub">로그인·세션 거부 중</span>
        </Link>
        <Link to="/admin/privileges" className="tile">
          <span className="tile__label">권한 정책 위반</span>
          <span className="tile__value">{protection.privilege_violations}명</span>
          <span className="tile__sub">허용목록 밖 관리자</span>
        </Link>
      </div>

      <div className="grid grid--2">
        <article className="panel">
          <header className="panel__head"><h2>인시던트 심각도</h2><Link to="/admin/incidents">인시던트 보기</Link></header>
          <ul className="severity">
            {SEVERITIES.map(([key, label]) => (
              <li key={key} className={`severity__item severity__item--${key}`}>
                <span>{label}</span><strong>{incidents.by_severity[key] ?? 0}</strong>
              </li>
            ))}
          </ul>
        </article>
        <article className="panel">
          <header className="panel__head"><h2>오래 기다린 문의</h2><Link to="/admin/support">문의 답변</Link></header>
          {support.oldest.length === 0 ? <p className="muted">대기 중인 문의가 없습니다.</p> : (
            <ul className="list">
              {support.oldest.map((t) => (
                <li key={t.id}><Link to={`/admin/support/${t.id}`}>{t.title}</Link><span className="tag">{STATUS_LABEL[t.status]}</span></li>
              ))}
            </ul>
          )}
        </article>
      </div>

      <h2 className="section-title">관제 지표</h2>
      <article className="panel grafana-snippet">
        <header className="panel__head">
          <h2>관제 그래프</h2>
          <Link to="/admin/grafana">관제 지표 전체 보기</Link>
        </header>
        {mon.loading ? (
          <Loading label="관제 화면 불러오는 중" />
        ) : embedUrl ? (
          <iframe
            className="grafana-frame grafana-frame--compact"
            src={embedUrl}
            title="L∞P 보안 관제 지표 (Grafana)"
            referrerPolicy="no-referrer"
            sandbox="allow-scripts allow-same-origin allow-popups"
          />
        ) : (
          <p className="muted">
            서버 <span className="mono">.env</span>에 <span className="mono">GRAFANA_PANEL_URL</span>(Grafana 패널 Share → Embed 의 주소)을 넣으면 그래프 하나가 여기에 표시됩니다.
            <Link to="/admin/grafana"> 설정 안내 보기</Link>
          </p>
        )}
      </article>
      <h2 className="section-title">관제 도구 바로가기</h2>
      <MonitoringLinks variant="cards" />
    </section>
  )
}
