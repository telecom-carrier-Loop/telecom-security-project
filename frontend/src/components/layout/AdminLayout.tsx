import { Link, NavLink, Outlet, useNavigate } from 'react-router-dom'
import { useAuth } from '../../app/providers/AuthProvider'
import { ROLE_LABEL } from '../../utils/format'
import Logo from '../common/Logo'
import MonitoringLinks from '../common/MonitoringLinks'

// 관리자 한 역할(ADMIN)이 고객 업무와 보안 업무를 모두 본다. 실제 차단은 서버 roles_required.
const MENU: [string, string][] = [
  ['/admin/customers', '회원 목록'],
  ['/admin/support', '문의 답변'],
  ['/admin/payments', '결제 관리'],
  ['/admin/benefits', '혜택 정책'],
  ['/admin/incidents', '보안 인시던트'],
]

export default function AdminLayout() {
  const { user, logout } = useAuth()
  const navigate = useNavigate()
  const onLogout = async () => { await logout(); navigate('/login') }
  return (
    <div className="shell shell--admin">
      <aside className="sidebar">
        <Link to="/admin" className="brand" aria-label="운영 대시보드로"><Logo suffix="운영" /></Link>
        <p className="sidebar__role">{user ? ROLE_LABEL[user.role] : ''} · {user?.name}</p>
        <nav aria-label="관리자 메뉴">
          <NavLink to="/admin" end className="nav__link">대시보드</NavLink>
          {MENU.map(([to, label]) => <NavLink key={to} to={to} className="nav__link">{label}</NavLink>)}
          <div className="nav__group">
            <NavLink to="/admin/settings" className="nav__link">프로필 설정</NavLink>
            <NavLink to="/" end className="nav__link">고객 화면으로</NavLink>
            <button type="button" className="nav__link nav__button" onClick={onLogout}>로그아웃</button>
          </div>
          <MonitoringLinks variant="nav" />
        </nav>
      </aside>
      <div className="main"><main id="content"><Outlet /></main></div>
    </div>
  )
}
