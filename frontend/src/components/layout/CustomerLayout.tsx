import { Link, NavLink, Outlet, useNavigate } from 'react-router-dom'
import { useAuth } from '../../app/providers/AuthProvider'
import Dropdown from '../common/Dropdown'
import Logo from '../common/Logo'
import { ThemeMenuItem, ThemeToggle } from '../common/ThemeControls'

const GROUPS = [
  { label: '상품서비스', links: [['/plans', '요금제 알아보기'], ['/usage', '내 회선 이용현황']] },
  { label: '혜택', links: [['/membership', 'L∞P+ 멤버십'], ['/membership/shop', '포인트 상점']] },
  { label: '고객지원', links: [['/notices', '공지사항'], ['/support', '1:1 문의']] },
  { label: 'MY', links: [['/usage', '내 이용현황'], ['/billing', '요금 조회·납부'], ['/settings', '프로필·보안 설정']] },
]

export default function CustomerLayout() {
  const { user, logout, isAdmin } = useAuth()
  const navigate = useNavigate()
  const onLogout = async () => { await logout(); navigate('/login') }
  return <div className="shell shell--customer">
    <a className="skip-link" href="#content">본문으로 이동</a>
    <header className="customer-header">
      <div className="customer-header__utility">
        <Link to="/" className="brand" aria-label="루프 홈으로"><Logo size="lg" /></Link>
        <div className="utility-links"><Link to="/membership">L∞P+</Link><Link to="/support">고객지원</Link>{isAdmin && <Link to="/admin">운영 콘솔</Link>}</div>
      </div>
      <div className="customer-header__main">
        <nav className="customer-navigation" aria-label="주 메뉴">
          {GROUPS.map(g => <Dropdown key={g.label} label={g.label} align="left" className="customer-navigation__group">
            {close => g.links.map(([to, label]) => <li key={to}><NavLink to={to} end onClick={close}>{label}</NavLink></li>)}
          </Dropdown>)}
        </nav>
        <div className="topnav__actions">
          <Dropdown label="전체 메뉴" className="customer-mobile-menu">
            {close => <>{GROUPS.map(g => <li key={g.label}><span className="user-menu__heading">{g.label}</span><ul className="mobile-submenu">{g.links.map(([to, label]) => <li key={to}><Link to={to} onClick={close}>{label}</Link></li>)}</ul></li>)}{isAdmin && <li><Link to="/admin" onClick={close}>운영 콘솔</Link></li>}</>}
          </Dropdown>
          <ThemeToggle />
          <Dropdown label={`${user?.name ?? ''}님`} className="topnav__user">
            {close => <>
              <li className="user-menu__meta">{user?.email}</li><ThemeMenuItem />
              <li className="user-menu__sep" role="separator" />
              <li><Link to="/settings" onClick={close}>프로필·보안 설정</Link></li>
              <li><Link to="/support" onClick={close}>1:1 문의</Link></li>
              <li><button type="button" onClick={() => { close(); onLogout() }}>로그아웃</button></li>
            </>}
          </Dropdown>
        </div>
      </div>
    </header>
    <div className="main"><main id="content"><Outlet /></main></div>
    <footer className="customer-footer">
      <div className="customer-footer__inner">
        <div className="customer-footer__links"><Link to="/notices">공지사항</Link><Link to="/support">고객지원</Link><Link to="/settings">내 정보 관리</Link><Link to="/plans">요금제 안내</Link></div>
        <div className="customer-footer__brand"><Logo /><p>일상과 일상 사이, 루프로 연결됩니다.</p></div>
        <p>L∞P(루프)는 보안 프로젝트용 가상 통신사입니다. 실제 결제·개인정보를 사용하지 않습니다.</p>
        <small>L∞P · 가상 통신 서비스 프로젝트</small>
      </div>
    </footer>
  </div>
}
