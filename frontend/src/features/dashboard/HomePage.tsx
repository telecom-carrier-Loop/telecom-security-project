import { useState } from 'react'
import { Link } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import ServiceIcon, { type ServiceIconName } from '../../components/common/ServiceIcon'
import type { DashboardSummary, Notice, Plan, ShopItem } from '../../services/types'
import { STATUS_LABEL, dataSize, dateTime, shortDate, won } from '../../utils/format'
import { useApi } from '../../utils/useApi'

const CAMPAIGNS = [
  { title: <>나의 하루에<br />딱 맞는 연결.</>, text: '요금제부터 이용현황까지, 나에게 맞는 통신 생활을 만나보세요.', to: '/plans', action: '요금제 알아보기', tone: 'lilac' },
  { title: <>매일의 혜택이<br />더 가까워지도록.</>, text: '사용 가능한 포인트와 멤버십 혜택을 한곳에서 확인하세요.', to: '/membership', action: '멤버십 둘러보기', tone: 'peach' },
  { title: <>필요한 도움을<br />빠르고 간편하게.</>, text: '궁금한 점은 1:1 문의로 남기고, 답변도 편리하게 확인하세요.', to: '/support', action: '고객지원 바로가기', tone: 'mint' },
]
const SHORTCUTS: [string, string, ServiceIconName][] = [
  ['/usage', '내 이용현황', 'usage'], ['/billing', '요금 납부', 'billing'], ['/plans', '요금제', 'plans'],
  ['/membership', '멤버십', 'membership'], ['/membership/shop', '포인트 상점', 'shop'], ['/support', '1:1 문의', 'support'],
]

export default function HomePage() {
  const summary = useApi<DashboardSummary>('/dashboard/summary')
  const shop = useApi<{ items: ShopItem[] }>('/membership/shop')
  const notices = useApi<{ notices: Notice[] }>('/notices')
  const plans = useApi<{ plans: Plan[] }>('/plans')
  const [slide, setSlide] = useState(0)
  if (summary.loading) return <Loading />
  if (summary.error || !summary.data) return <ErrorState error={summary.error} onRetry={summary.reload} />
  const { user, subscription, usage, billing, membership, recent_tickets, recent_payments } = summary.data
  const unlimited = !!usage && usage.data_limit_mb < 0
  const left = usage && !unlimited ? Math.max(usage.data_limit_mb - usage.data_used_mb, 0) : null
  const ratio = usage && usage.data_limit_mb > 0 ? Math.max(0, Math.min(1, (left ?? 0) / usage.data_limit_mb)) : unlimited ? 1 : 0
  const campaign = CAMPAIGNS[slide]
  const picks = (shop.data?.items ?? []).filter(i => i.available).slice(0, 3)
  return <section className="page home-page">
    {user.failed_attempts_before_login > 0 && <div className="notice notice--warn" role="alert">지난 로그인 이후 로그인 실패가 {user.failed_attempts_before_login}회 있었습니다. 본인이 시도한 게 아니라면 <Link to="/settings">비밀번호를 변경하세요</Link>.</div>}
    <section className={`portal-hero portal-hero--${campaign.tone}`} aria-label="루프 서비스 안내">
      <div className="portal-hero__copy" id="campaign-content" role="tabpanel" aria-labelledby={`campaign-tab-${slide}`}>
        <h1>{campaign.title}</h1><p>{campaign.text}</p>
        <Link className="btn btn--hero" to={campaign.to}>{campaign.action}<ServiceIcon name="arrow" size={18} /></Link>
      </div>
      <img className="portal-hero__image" src="/images/brand/loop-devices.webp" alt="" width="1672" height="941" />
      <div className="campaign-control"><span className="campaign-control__count" aria-hidden="true">{String(slide + 1).padStart(2, '0')} / 03</span><div role="tablist" aria-label="서비스 안내 선택">{CAMPAIGNS.map((c, i) => <button type="button" id={`campaign-tab-${i}`} key={c.to} role="tab" aria-selected={slide === i} aria-controls="campaign-content" tabIndex={slide === i ? 0 : -1} aria-label={c.action} onClick={() => setSlide(i)} onKeyDown={e => { if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) { e.preventDefault(); const next = e.key === 'Home' ? 0 : e.key === 'End' ? 2 : (i + (e.key === 'ArrowRight' ? 1 : 2)) % 3; setSlide(next); document.getElementById(`campaign-tab-${next}`)?.focus() } }} />)}</div></div>
    </section>
    <section className="my-overview" aria-label="내 통신 생활 요약">
      <div className="my-overview__welcome"><span>반가워요, {user.name}님</span><h2>나의 통신 생활</h2><p>{subscription ? subscription.plan.name : '가입한 회선이 없습니다'}</p><span className="muted">{subscription?.phone_number}</span><Link to="/usage">MY 전체 보기 <span aria-hidden="true">→</span></Link></div>
      <Link to="/usage" className="overview-stat"><span>남은 데이터</span><strong>{!subscription ? '회선 없음' : !usage ? '수집 대기' : unlimited ? '무제한' : dataSize(left ?? 0)}</strong><span className="data-track" aria-hidden="true"><span style={{ width: `${ratio * 100}%` }} /></span><small>{usage ? unlimited ? '데이터 무제한 요금제' : `기본 제공 ${dataSize(usage.data_limit_mb)}` : '이용현황에서 자세히 보기'}</small></Link>
      <Link to="/billing" className="overview-stat"><span>이번 달 납부할 요금</span><strong>{won(billing.amount_due)}</strong><small>{billing.next_due_date ? `${shortDate(billing.next_due_date)}까지 납부` : '미납 요금이 없어요'}</small><span className="overview-stat__action">요금 조회·납부 →</span></Link>
      <Link to="/membership" className="overview-stat"><span>{membership ? `L∞P+ ${membership.tier}` : 'L∞P+ 멤버십'}</span><strong>{membership ? `${membership.point_balance.toLocaleString()}P` : '미가입'}</strong><small>{membership ? '사용 가능한 포인트' : '멤버십 혜택을 만나보세요'}</small><span className="overview-stat__action">멤버십 보기 →</span></Link>
    </section>
    <nav className="service-shortcuts" aria-label="자주 찾는 메뉴">{SHORTCUTS.map(([to, label, icon]) => <Link key={to} to={to}><span className="service-shortcuts__icon"><ServiceIcon name={icon} size={30} /></span><span>{label}</span></Link>)}</nav>
    <section className="home-section">
      <header className="home-section__head"><div><h2>나에게 맞는 요금제 찾기</h2><p>데이터도 요금도, 내 생활에 맞게 선택하세요.</p></div><Link to="/plans">전체 요금제 <ServiceIcon name="arrow" size={18} /></Link></header>
      {plans.loading ? <Loading label="요금제 불러오는 중" /> : plans.error ? <ErrorState error={plans.error} onRetry={plans.reload} /> : !plans.data?.plans.length ? <p className="muted">현재 조회 가능한 요금제가 없습니다.</p> : <div className="featured-plans">{plans.data.plans.slice(0, 3).map(p => <Link to="/plans" className="featured-plan" key={p.id}><span className="featured-plan__network">{p.network}</span><h3>{p.name}</h3><strong>{dataSize(p.data_mb)}</strong><p>음성 {p.voice_minutes < 0 ? '무제한' : `${p.voice_minutes}분`}</p><div className="featured-plan__bottom"><span>월 <b>{won(p.monthly_fee)}</b></span><ServiceIcon name="arrow" size={20} /></div></Link>)}</div>}
    </section>
    <section className="membership-feature"><div><h2>일상에 더하는<br /><span>L∞P+ 멤버십</span></h2><p>내 포인트로 만나는 다양한 혜택.<br />사용 가능한 상품을 확인해 보세요.</p><Link to="/membership" className="text-link">내 멤버십 확인 <ServiceIcon name="arrow" size={18} /></Link></div><div className="benefit-selection">{shop.loading ? <Loading label="혜택 불러오는 중" /> : shop.error ? <ErrorState error={shop.error} onRetry={shop.reload} /> : picks.length ? picks.map(i => <Link key={i.id} to="/membership/shop" className="benefit-item"><span className="benefit-item__symbol"><ServiceIcon name="shop" size={26} /></span><div><h3>{i.name}</h3><span>{i.price_points.toLocaleString()}P</span></div><ServiceIcon name="arrow" size={18} /></Link>) : <p className="muted">현재 사용 가능한 상품이 없습니다. <Link to="/membership/shop">상점 보기</Link></p>}</div></section>
    <section className="home-section"><header className="home-section__head"><div><h2>루프가 도와드릴게요</h2><p>필요한 안내와 나의 처리 내역을 확인하세요.</p></div><Link to="/support">고객지원 <ServiceIcon name="arrow" size={18} /></Link></header>
      <div className="home-activity"><article><header className="panel__head"><h3>최근 문의</h3><Link to="/support">전체 보기</Link></header>{recent_tickets.length ? <ul className="list">{recent_tickets.map(t => <li key={t.id}><Link to={`/support/${t.id}`}>{t.title}</Link><span className="tag">{STATUS_LABEL[t.status]}</span></li>)}</ul> : <p className="muted">아직 남긴 문의가 없습니다.</p>}</article><article><header className="panel__head"><h3>최근 결제</h3><Link to="/billing">전체 보기</Link></header>{recent_payments.length ? <ul className="list">{recent_payments.map(p => <li key={p.id}><span>{won(p.amount)}</span><span className="tag">{STATUS_LABEL[p.status]}</span></li>)}</ul> : <p className="muted">최근 결제 내역이 없습니다.</p>}</article></div>
    </section>
    <section className="notice-strip"><h2>공지사항</h2><div>{notices.loading ? <span className="muted">공지 불러오는 중</span> : notices.error ? <span className="muted">공지를 불러오지 못했습니다.</span> : notices.data?.notices[0] ? <Link to={`/notices/${notices.data.notices[0].id}`}>{notices.data.notices[0].title}</Link> : <span className="muted">등록된 공지가 없습니다.</span>}</div><Link to="/notices" aria-label="공지사항 전체 보기"><ServiceIcon name="arrow" size={20} /></Link></section>
    <p className="muted security-line">이전 로그인: {dateTime(user.previous_login_at)} · <Link to="/settings">계정 보안 설정</Link></p>
  </section>
}
