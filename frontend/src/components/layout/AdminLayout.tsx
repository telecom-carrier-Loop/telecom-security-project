import { Link, NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { useAuth } from '../../app/providers/AuthProvider'
import type { MonitoringLink } from '../../services/types'
import { ROLE_LABEL } from '../../utils/format'
import { useApi } from '../../utils/useApi'
import Dropdown from '../common/Dropdown'
import Logo from '../common/Logo'

// 상단 메뉴: 대시보드는 로고, 서비스 메뉴는 펼쳐 두고 보안·관제 도구는 드롭다운으로 묶는다.
const SERVICE_MENU: [string, string][] = [
  ['/admin/customers', '회원'],
  ['/admin/support', '문의 답변'],
  ['/admin/payments', '결제'],
  ['/admin/benefits', '혜택'],
  ['/admin/shop', '포인트 상점'],
  ['/admin/notices', '공지사항'],
]
const SECURITY_MENU: [string, string][] = [
  ['/admin/incidents', '보안 인시던트'],
  ['/admin/ip-blocks', '차단 IP'],
  ['/admin/privileges', '권한 점검'],
  ['/admin/automation', '자동화 현황'],
  ['/admin/grafana', '관제 지표'],
]

export default function AdminLayout() {
  const { user, logout } = useAuth()
  const navigate = useNavigate()
  const { pathname } = useLocation()
  const tools = useApi<{ links: MonitoringLink[] }>('/admin/monitoring-links')
  const onLogout = async () => { await logout(); navigate('/login') }
  const inSecurity = SECURITY_MENU.some(([to]) => pathname.startsWith(to))

  return (
    <div className="shell shell--admin">
      <header className="topnav">
        <Link to="/admin" className="topnav__brand brand" aria-label="운영 대시보드로"><Logo suffix="운영" /></Link>
        <nav className="topnav__menu" aria-label="관리자 메뉴">
          {SERVICE_MENU.map(([to, label]) => <NavLink key={to} to={to} className="nav__link">{label}</NavLink>)}
          <Dropdown label="보안" align="left" className={`nav__drop ${inSecurity ? 'nav__drop--active' : ''}`}>
            {(close) => SECURITY_MENU.map(([to, label]) => (
              <li key={to}><Link to={to} onClick={close} aria-current={pathname.startsWith(to) ? 'page' : undefined}>{label}</Link></li>
            ))}
          </Dropdown>
          <Dropdown label="관제 도구" align="left" className="nav__drop">
            {(close) => (tools.data?.links ?? []).map((l) => (
              <li key={l.key}>
                {l.url
                  ? <a href={l.url} target="_blank" rel="noopener noreferrer" onClick={close}>{l.name} <span aria-hidden="true">↗</span></a>
                  : <span className="user-menu__meta">{l.name} (주소 미설정)</span>}
              </li>
            ))}
          </Dropdown>
        </nav>
        <Dropdown label={`${user?.name ?? ''}님`} className="topnav__user">
          {(close) => (
            <>
              <li className="user-menu__meta">{user ? ROLE_LABEL[user.role] : ''} · {user?.email}</li>
              <li><Link to="/admin/settings" onClick={close}>프로필 설정</Link></li>
              <li><Link to="/" onClick={close}>고객 화면으로</Link></li>
              <li className="user-menu__sep" role="separator" />
              <li><button type="button" onClick={() => { close(); onLogout() }}>로그아웃</button></li>
            </>
          )}
        </Dropdown>
      </header>
      <div className="main"><main id="content"><Outlet /></main></div>
    </div>
  )
}
