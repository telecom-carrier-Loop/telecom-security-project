import { Link } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import type { DashboardSummary, Notice, ShopItem } from '../../services/types'
import { STATUS_LABEL, dataSize, dateTime, shortDate, won } from '../../utils/format'
import { useApi } from '../../utils/useApi'

// 원형 데이터 게이지: 남은 비율을 링으로, 가운데에 남은 양
function Ring({ ratio, label, sub }: { ratio: number; label: string; sub: string }) {
  const r = 38, c = 2 * Math.PI * r, left = Math.max(0, Math.min(ratio, 1))
  return (
    <svg className="ring" width="120" height="120" viewBox="0 0 96 96" role="img" aria-label={`${label} ${sub}`}>
      <circle cx="48" cy="48" r={r} fill="none" stroke="var(--ring-track)" strokeWidth="10" />
      <circle cx="48" cy="48" r={r} fill="none" stroke="var(--signal)" strokeWidth="10" strokeLinecap="round"
              strokeDasharray={`${c * left} ${c}`} transform="rotate(-90 48 48)" />
      <text x="48" y="47" textAnchor="middle" fontSize="16" fontWeight="600" fill="var(--ink)">{label}</text>
      <text x="48" y="62" textAnchor="middle" fontSize="9.5" fill="var(--ink-soft)">{sub}</text>
    </svg>
  )
}

const Icon = ({ d }: { d: string }) => (
  <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={d} /></svg>
)
const ICON = {
  pay: 'M3 7h18v11H3zM3 11h18',
  kakao: 'M12 4c-5 0-9 3-9 6.7 0 2.4 1.6 4.4 4 5.6L6 20l4.2-2.6c.6.1 1.2.1 1.8.1 5 0 9-3 9-6.8S17 4 12 4z',
  shop: 'M5 8h14l-1 12H6zM9 8V6a3 3 0 0 1 6 0v2',
  ask: 'M4 5h16v11H9l-5 4z',
  notice: 'M4 10v4h3l5 4V6L7 10zM16 9a4 4 0 0 1 0 6',
}

// 고객 홈 (브랜드 볼드): 파란 배너 + 원형 게이지 카드 + 둥근 바로가기 + 추천·공지
export default function HomePage() {
  const { loading, error, data, reload } = useApi<DashboardSummary>('/dashboard/summary')
  const shop = useApi<{ items: ShopItem[] }>('/membership/shop')
  const notices = useApi<{ notices: Notice[] }>('/notices')
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} onRetry={reload} />

  const { user, subscription, usage, billing, membership, recent_tickets, recent_payments } = data
  const unlimited = !!usage && usage.data_limit_mb < 0
  const left = usage && !unlimited ? Math.max(usage.data_limit_mb - usage.data_used_mb, 0) : null
  const leftRatio = usage && !unlimited ? (left ?? 0) / usage.data_limit_mb : unlimited ? 1 : 0
  const greet = !subscription ? '요금제를 골라 보세요'
    : unlimited ? '이번 달도 마음껏 쓰고 있어요'
    : leftRatio > 0.5 ? '이번 달도 넉넉해요'
    : leftRatio > 0.2 ? '절반 넘게 썼어요' : '데이터가 얼마 남지 않았어요'
  const picks = (shop.data?.items ?? []).filter((i) => i.available).slice(0, 2)
  const notice = notices.data?.notices?.[0]

  return (
    <section className="page">
      {user.failed_attempts_before_login > 0 && (
        <div className="notice notice--warn" role="alert">
          지난 로그인 이후 로그인 실패가 {user.failed_attempts_before_login}회 있었습니다.
          본인이 시도한 게 아니라면 <Link to="/settings">비밀번호를 변경하세요</Link>.
        </div>
      )}

      <div className="hero">
        <h1 className="hero__greet">{user.name}님, {greet}</h1>
        <p className="hero__sub">{subscription ? `${subscription.plan.name} · ${subscription.phone_number}` : '회선이 없습니다'}</p>
      </div>

      <div className="hero-card">
        <Link to="/usage" aria-label="내 이용현황 자세히">
          <Ring ratio={leftRatio}
                label={!subscription ? '-' : unlimited ? '무제한' : left !== null ? dataSize(left) : '-'}
                sub={unlimited ? '데이터' : '남음'} />
        </Link>
        <div className="hero-card__minis">
          <Link to="/billing" className="mini">
            <span className="mini__label">이번 달 요금</span>
            <span className="mini__value">{won(billing.amount_due)}</span>
            <span className={billing.next_due_date ? 'mini__sub mini__sub--alert' : 'mini__sub'}>
              {billing.next_due_date ? `${shortDate(billing.next_due_date)}까지` : '미납 요금이 없어요'}
            </span>
          </Link>
          <Link to="/membership" className="mini">
            <span className="mini__label">{membership ? `L∞P+ ${membership.tier}` : 'L∞P+ 멤버십'}</span>
            <span className="mini__value">{membership ? `${membership.point_balance.toLocaleString()}P` : '미가입'}</span>
            <span className="mini__sub">{membership ? '사용 가능한 포인트' : '가입하고 혜택 받기'}</span>
          </Link>
        </div>
      </div>

      <nav className="shortcuts" aria-label="바로가기">
        <Link to="/billing"><Icon d={ICON.pay} />요금 납부</Link>
        <Link to="/billing" className="shortcuts__kakao"><Icon d={ICON.kakao} />카카오페이</Link>
        <Link to="/membership/shop"><Icon d={ICON.shop} />포인트 상점</Link>
        <Link to="/support"><Icon d={ICON.ask} />1:1 문의</Link>
        <Link to="/notices"><Icon d={ICON.notice} />공지사항</Link>
      </nav>

      {(picks.length > 0 || notice) && (
        <div className="picks">
          {picks.map((i) => (
            <Link key={i.id} to="/membership/shop" className="pick">
              <span className="pick__label">{membership ? `${membership.tier} 추천` : '포인트 상점'}</span>
              <span className="pick__title">{i.name}</span>
              <span className="muted">{i.price_points.toLocaleString()}P</span>
            </Link>
          ))}
          {notice && (
            <Link to={`/notices/${notice.id}`} className="pick">
              <span className="pick__label">공지 · {notice.category_label}</span>
              <span className="pick__title">{notice.title}</span>
              <span className="muted">{shortDate(notice.published_at)}</span>
            </Link>
          )}
        </div>
      )}

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
