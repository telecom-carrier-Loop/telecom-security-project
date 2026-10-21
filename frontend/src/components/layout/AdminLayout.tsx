import { useEffect, useRef, useState } from 'react'
import { Link, NavLink, Outlet, useNavigate } from 'react-router-dom'
import { useAuth } from '../../app/providers/AuthProvider'
import { ROLE_LABEL } from '../../utils/format'
import Logo from '../common/Logo'
import MonitoringLinks from '../common/MonitoringLinks'

const SERVICE_MENU: [string, string][] = [
  ['/admin/customers', '회원 목록'],
  ['/admin/support', '문의 답변'],
  ['/admin/payments', '결제 관리'],
  ['/admin/benefits', '혜택 정책'],
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
  const [open, setOpen] = useState(false)
  const menuRef = useRef<HTMLDivElement>(null)

  const onLogout = async () => {
    setOpen(false)
    await logout()
    navigate('/login')
  }

  useEffect(() => {
    if (!open) return
    const onDoc = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) setOpen(false)
    }
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('mousedown', onDoc)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onDoc)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  return (
    <div className="shell shell--admin">
      <header className="topnav">
        <Link to="/admin" className="topnav__brand brand" aria-label="운영 대시보드로">
          <Logo suffix="운영" />
        </Link>
        <nav className="topnav__menu" aria-label="관리자 메뉴">
          {SERVICE_MENU.map(([to, label]) => (
            <NavLink key={to} to={to} className="nav__link">{label}</NavLink>
          ))}
          {SECURITY_MENU.map(([to, label]) => (
            <NavLink key={to} to={to} className="nav__link">{label}</NavLink>
          ))}
        </nav>
        <div className="topnav__user" ref={menuRef}>
          <button type="button" className="topnav__user-btn" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
            {user?.name}님 ▾
          </button>
          {open && (
            <ul className="user-menu">
              <li className="user-menu__meta">
                {user ? ROLE_LABEL[user.role] : ''} · {user?.name}
              </li>
              <li><Link to="/admin/settings" onClick={() => setOpen(false)}>프로필 설정</Link></li>
              <li><Link to="/" onClick={() => setOpen(false)}>고객 화면으로</Link></li>
              <li><button type="button" onClick={onLogout}>로그아웃</button></li>
            </ul>
          )}
        </div>
      </header>
      <div className="main">
        <main id="content"><Outlet /></main>
      </div>
      {/* 관제 도구 링크가 필요하면 본문 하단/대시보드에 두고, 상단이 너무 길면 여기선 빼도 됨 */}
      {/* <MonitoringLinks variant="nav" /> */}
    </div>
  )
}