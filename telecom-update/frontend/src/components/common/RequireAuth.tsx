import { Navigate, Outlet, useLocation } from 'react-router-dom'
import { useAuth } from '../../app/providers/AuthProvider'
import type { Role } from '../../services/types'
import Loading from './Loading'

// 화면 보호는 사용성용일 뿐, 실제 차단은 항상 Flask가 한다.
export default function RequireAuth({ roles }: { roles?: Role[] }) {
  const { user, checking } = useAuth()
  const location = useLocation()
  if (checking) return <Loading />
  if (!user) return <Navigate to="/login" replace state={{ from: location.pathname }} />
  if (roles && !roles.includes(user.role)) return <Navigate to={user.role === 'CUSTOMER' ? '/' : '/admin'} replace />
  return <Outlet />
}
