import { NavLink } from 'react-router-dom'

export default function BlockNavigation() {
  return <nav className="quick" aria-label="보안 차단 목록">
    <NavLink to="/admin/ip-blocks" className={({ isActive }) => isActive ? 'chip chip--on' : 'chip'}>차단 IP</NavLink>
    <NavLink to="/admin/account-locks" className={({ isActive }) => isActive ? 'chip chip--on' : 'chip'}>차단 계정</NavLink>
  </nav>
}
