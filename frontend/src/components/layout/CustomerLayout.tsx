import { useEffect, useRef, useState } from 'react'
import { Link, NavLink, Outlet, useNavigate } from 'react-router-dom'
import { useAuth } from '../../app/providers/AuthProvider'
import Logo from '../common/Logo'

const NAV = [
  { to: '/usage', label: '내 이용현황' },
  { to: '/plans', label: '요금제' },
  { to: '/billing', label: '요금 납부' },
  { to: '/membership', label: 'L∞P+ 멤버십' },
]

export default function CustomerLayout() {
  const { user, logout, isAdmin } = useAuth()
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
    <div className="shell">
      <header className="topnav">
        <Link to="/" className="topnav__brand brand" aria-label="홈으로"><Logo /></Link>
        <nav className="topnav__menu" aria-label="고객 메뉴">
          {NAV.map((n) => (
            <NavLink key={n.to} to={n.to} className="nav__link">{n.label}</NavLink>
          ))}
          {isAdmin && <NavLink to="/admin" end className="nav__link">관리자 화면</NavLink>}
        </nav>
        <div className="topnav__user" ref={menuRef}>
          <button type="button" className="topnav__user-btn" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
            {user?.name}님 ▾
          </button>
          {open && (
            <ul className="user-menu">
              <li><Link to="/settings" onClick={() => setOpen(false)}>프로필 설정</Link></li>
              <li><Link to="/support" onClick={() => setOpen(false)}>1:1 문의</Link></li>
              <li><button type="button" onClick={onLogout}>로그아웃</button></li>
            </ul>
          )}
        </div>
      </header>
      <div className="main">
        <main id="content"><Outlet /></main>
        <footer className="footer">L∞P(루프)는 보안 프로젝트용 가상 통신사입니다. 실제 결제·개인정보를 사용하지 않습니다.</footer>
      </div>
    </div>
  )
}