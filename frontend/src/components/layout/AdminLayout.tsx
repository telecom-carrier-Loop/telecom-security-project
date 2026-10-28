import { Link, NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { useAuth } from '../../app/providers/AuthProvider'
import type { MonitoringLink } from '../../services/types'
import { ROLE_LABEL } from '../../utils/format'
import { useApi } from '../../utils/useApi'
import Dropdown from '../common/Dropdown'
import Logo from '../common/Logo'
import { ThemeMenuItem, ThemeToggle } from '../common/ThemeControls'

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
  const currentPage = [...SERVICE_MENU, ...SECURITY_MENU].find(([to]) => pathname.startsWith(to))?.[1] ?? '운영 대시보드'

  return (
    <div className="shell shell--admin">
      <a className="skip-link" href="#content">본문으로 이동</a>
      <aside className="admin-sidebar" aria-label="운영 탐색">
        <Link to="/admin" className="brand" aria-label="운영 대시보드로"><Logo suffix="운영" /></Link>
        <nav aria-label="관리자 메뉴">
          <NavLink to="/admin" end className="nav__link">운영 대시보드</NavLink>
          <h2>고객 업무</h2>
          {SERVICE_MENU.map(([to, label]) => <NavLink key={to} to={to} className="nav__link">{label}</NavLink>)}
          <h2>보안 관리</h2>
          {SECURITY_MENU.map(([to, label]) => <NavLink key={to} to={to} className="nav__link">{label}</NavLink>)}
          <h2>관제 도구</h2>
          {(tools.data?.links ?? []).map(l => l.url
            ? <a key={l.key} className="nav__link nav__external" href={l.url} target="_blank" rel="noopener noreferrer">{l.name}<span aria-hidden="true">↗</span></a>
            : <span key={l.key} className="admin-sidebar__unavailable">{l.name} · 미설정</span>)}
          {tools.error && <span className="admin-sidebar__unavailable">도구 목록 조회 실패</span>}
        </nav>
      </aside>
      <header className="topnav">
        <span className="admin-location">루프 운영 / <strong>{currentPage}</strong></span>
        <Dropdown label="전체 메뉴" align="left" className="admin-mobile-menu">
          {close => <>
            {[['/admin', '운영 대시보드'], ...SERVICE_MENU, ...SECURITY_MENU].map(([to, label]) => <li key={to}><Link to={to} onClick={close}>{label}</Link></li>)}
            <li className="user-menu__sep" role="separator" />
            {(tools.data?.links ?? []).map(l => <li key={l.key}>{l.url
              ? <a href={l.url} target="_blank" rel="noopener noreferrer" onClick={close}>{l.name} ↗</a>
              : <span className="user-menu__meta">{l.name} · 미설정</span>}</li>)}
            {tools.error && <li className="user-menu__meta">관제 도구 목록 조회 실패</li>}
          </>}
        </Dropdown>
        <div className="topnav__actions">
          <ThemeToggle />
          <Dropdown label={`${user?.name ?? ''}님`} className="topnav__user">
            {(close) => (
              <>
                <li className="user-menu__meta">{user ? ROLE_LABEL[user.role] : ''} · {user?.email}</li>
                <ThemeMenuItem />
                <li className="user-menu__sep" role="separator" />
                <li><Link to="/admin/settings" onClick={close}>프로필 설정</Link></li>
                <li><Link to="/" onClick={close}>고객 화면으로</Link></li>
                <li className="user-menu__sep" role="separator" />
                <li><button type="button" onClick={() => { close(); onLogout() }}>로그아웃</button></li>
              </>
            )}
          </Dropdown>
        </div>
      </header>
      <div className="main"><main id="content"><Outlet /></main></div>
    </div>
  )
}
