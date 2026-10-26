import { Link, NavLink, Outlet, useNavigate } from 'react-router-dom'
import { useAuth } from '../../app/providers/AuthProvider'
import Dropdown from '../common/Dropdown'
import Logo from '../common/Logo'
import { ThemeMenuItem, ThemeToggle } from '../common/ThemeControls'

// 홈은 로고를 누르면 간다. 프로필·1:1 문의·로그아웃은 이름 메뉴에.
const NAV = [
  { to: '/usage', label: '내 이용현황' },
  { to: '/plans', label: '요금제' },
  { to: '/billing', label: '요금 납부' },
  { to: '/membership', label: 'L∞P+ 멤버십', end: true },
  { to: '/membership/shop', label: '포인트 상점' },
  { to: '/notices', label: '공지사항' },
]

export default function CustomerLayout() {
  const { user, logout, isAdmin } = useAuth()
  const navigate = useNavigate()
  const onLogout = async () => { await logout(); navigate('/login') }

  return (
    <div className="shell">
      <header className="topnav">
        <Link to="/" className="topnav__brand brand" aria-label="L∞P 홈으로"><Logo /></Link>
        <nav className="topnav__menu" aria-label="고객 메뉴">
          {NAV.map((n) => <NavLink key={n.to} to={n.to} end={n.end} className="nav__link">{n.label}</NavLink>)}
          {isAdmin && <NavLink to="/admin" className="nav__link">관리자 화면</NavLink>}
        </nav>
        <div className="topnav__actions">
          <ThemeToggle />
          <Dropdown label={`${user?.name ?? ''}님`} className="topnav__user">
            {(close) => (
              <>
                <li className="user-menu__meta">{user?.email}</li>
                <ThemeMenuItem />
                <li className="user-menu__sep" role="separator" />
                <li><Link to="/settings" onClick={close}>프로필 설정</Link></li>
                <li><Link to="/support" onClick={close}>1:1 문의</Link></li>
                <li className="user-menu__sep" role="separator" />
                <li><button type="button" onClick={() => { close(); onLogout() }}>로그아웃</button></li>
              </>
            )}
          </Dropdown>
        </div>
      </header>
      <div className="main">
        <main id="content"><Outlet /></main>
        <footer className="footer">L∞P(루프)는 보안 프로젝트용 가상 통신사입니다. 실제 결제·개인정보를 사용하지 않습니다.</footer>
      </div>
    </div>
  )
}
