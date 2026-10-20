import { Link } from 'react-router-dom'
import Logo from '../../components/common/Logo'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import { STATUS_LABEL, dataSize, dateTime, shortDate, won } from '../../utils/format'
import type { DashboardSummary } from '../../services/types'
import { useApi } from '../../utils/useApi'

// 홈: 로그인하면 처음 보는 화면. 숫자 세 개 + 바로가기 + 최근 활동 + 계정 보안
export default function HomePage() {
  const { loading, error, data, reload } = useApi<DashboardSummary>('/dashboard/summary')
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} onRetry={reload} />

  const { user, subscription, usage, billing, membership, recent_tickets, recent_payments } = data
  const unlimited = usage && usage.data_limit_mb < 0
  const dataLeft = usage && !unlimited ? Math.max(usage.data_limit_mb - usage.data_used_mb, 0) : null
  const usedRatio = usage && !unlimited ? usage.data_used_mb / usage.data_limit_mb : 0

  return (
    <section className="page">
      <h1 className="page__title">{user.name}님, 안녕하세요</h1>

      {user.failed_attempts_before_login > 0 && (
        <div className="notice notice--warn" role="alert">
          지난 로그인 이후 로그인 실패가 {user.failed_attempts_before_login}회 있었습니다.
          본인이 시도한 게 아니라면 <Link to="/settings">비밀번호를 변경하세요</Link>.
        </div>
      )}

      <div className="grid">
        <Link to="/usage" className="tile">
          <span className="tile__label">남은 데이터</span>
          <span className="tile__value">
            {!subscription ? '회선 없음' : unlimited ? '무제한' : usage && dataLeft !== null ? dataSize(dataLeft) : '-'}
          </span>
          {usage && !unlimited && (
            <span className="minibar" aria-hidden="true"><span style={{ width: `${Math.min(usedRatio, 1) * 100}%` }} /></span>
          )}
          <span className="tile__sub">{subscription ? subscription.plan.name : '요금제를 선택하세요'}</span>
        </Link>
        <Link to="/billing" className="tile">
          <span className="tile__label">납부할 금액</span>
          <span className="tile__value">{won(billing.amount_due)}</span>
          <span className="tile__sub">
            {billing.next_due_date ? `${shortDate(billing.next_due_date)}까지` : '미납 요금이 없습니다'}
          </span>
        </Link>
        <Link to="/membership" className="tile">
          <span className="tile__label"><Logo variant="plus" size="sm" /> 포인트</span>
          <span className="tile__value">{membership ? `${membership.point_balance.toLocaleString()}P` : '미가입'}</span>
          <span className="tile__sub">{membership ? '사용 가능한 포인트' : '가입하고 혜택 받기'}</span>
        </Link>
      </div>

      <nav className="quick" aria-label="바로가기">
        <Link to="/billing">요금 납부</Link>
        <Link to="/support">문의 남기기</Link>
        <Link to="/plans">요금제 비교</Link>
        <Link to="/settings">비밀번호 변경</Link>
      </nav>

      <div className="grid grid--2">
        <article className="panel">
          <header className="panel__head"><h2>최근 문의</h2><Link to="/support">전체 보기</Link></header>
          {recent_tickets.length === 0 ? <p className="muted">남긴 문의가 없습니다.</p> : (
            <ul className="list">
              {recent_tickets.map((t) => (
                <li key={t.id}><span>{t.title}</span><span className="tag">{STATUS_LABEL[t.status]}</span></li>
              ))}
            </ul>
          )}
        </article>
        <article className="panel">
          <header className="panel__head"><h2>최근 결제</h2><Link to="/billing">전체 보기</Link></header>
          {recent_payments.length === 0 ? <p className="muted">결제 내역이 없습니다.</p> : (
            <ul className="list">
              {recent_payments.map((p) => (
                <li key={p.id}><span>{won(p.amount)}</span><span className="tag">{STATUS_LABEL[p.status]}</span></li>
              ))}
            </ul>
          )}
        </article>
      </div>

      <p className="muted security-line">
        이전 로그인: {dateTime(user.previous_login_at)} · <Link to="/settings">계정 보안 설정</Link>
      </p>
    </section>
  )
}
