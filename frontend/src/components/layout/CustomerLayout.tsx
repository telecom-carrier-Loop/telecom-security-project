import { Link, NavLink, Outlet, useNavigate } from 'react-router-dom'
import { useAuth } from '../../app/providers/AuthProvider'
import Logo from '../common/Logo'

const NAV = [
  { to: '/', label: '홈', end: true },
  { to: '/usage', label: '내 이용현황' },
  { to: '/plans', label: '요금제' },
  { to: '/billing', label: '요금 납부' },
  { to: '/membership', label: 'L∞P+ 멤버십' },
  { to: '/support', label: '1:1 문의' },
]

export default function CustomerLayout() {
  const { user, logout, isAdmin } = useAuth()
  const navigate = useNavigate()
  const onLogout = async () => { await logout(); navigate('/login') }

  return (
    <div className="shell">
      <aside className="sidebar">
        <Link to="/" className="brand" aria-label="홈으로"><Logo /></Link>
        <nav aria-label="고객 메뉴">
          {NAV.map((n) => (
            <NavLink key={n.to} to={n.to} end={n.end} className="nav__link">{n.label}</NavLink>
          ))}
          <div className="nav__group">
            <NavLink to="/settings" className="nav__link">프로필 설정</NavLink>
            {isAdmin && <NavLink to="/admin" end className="nav__link">관리자 화면</NavLink>}
          </div>
        </nav>
      </aside>
      <div className="main">
        <header className="topbar">
          <Link to="/settings" className="topbar__user">{user?.name}님</Link>
          <button className="btn btn--ghost" onClick={onLogout}>로그아웃</button>
        </header>
        <main id="content"><Outlet /></main>
        <footer className="footer">L∞P(루프)는 보안 프로젝트용 가상 통신사입니다. 실제 결제·개인정보를 사용하지 않습니다.</footer>
      </div>
    </div>
  )
}
