import { createBrowserRouter, Navigate } from 'react-router-dom'
import RequireAuth from '../../components/common/RequireAuth'
import AdminLayout from '../../components/layout/AdminLayout'
import CustomerLayout from '../../components/layout/CustomerLayout'
import AdminDashboardPage from '../../features/dashboard/AdminDashboardPage'
import AdminCustomerDetailPage from '../../features/auth/AdminCustomerDetailPage'
import AdminCustomersPage from '../../features/auth/AdminCustomersPage'
import LoginPage from '../../features/auth/LoginPage'
import RegisterPage from '../../features/auth/RegisterPage'
import HomePage from '../../features/dashboard/HomePage'
import UsagePage from '../../features/dashboard/UsagePage'
import AdminIncidentDetailPage from '../../features/incidents/AdminIncidentDetailPage'
import AdminIncidentsPage from '../../features/incidents/AdminIncidentsPage'
import AdminAutomationPage from '../../features/incidents/AdminAutomationPage'
import AdminIpBlocksPage from '../../features/incidents/AdminIpBlocksPage'
import AdminPrivilegesPage from '../../features/incidents/AdminPrivilegesPage'
import AdminBenefitsPage from '../../features/membership/AdminBenefitsPage'
import MembershipPage from '../../features/membership/MembershipPage'
import AdminPaymentsPage from '../../features/payments/AdminPaymentsPage'
import BillingPage from '../../features/payments/BillingPage'
import PlansPage from '../../features/plans/PlansPage'
import ProfileSettingsPage from '../../features/auth/ProfileSettingsPage'
import AdminSupportPage from '../../features/support/AdminSupportPage'
import SupportDetailPage from '../../features/support/SupportDetailPage'
import SupportPage from '../../features/support/SupportPage'
import type { Role } from '../../services/types'

const ADMIN_ROLES: Role[] = ['ADMIN']

export const router = createBrowserRouter([
  { path: '/login', element: <LoginPage /> },
  { path: '/register', element: <RegisterPage /> },
  {
    element: <RequireAuth />,
    children: [{
      element: <CustomerLayout />,
      children: [
        { index: true, element: <HomePage /> },
        { path: 'usage', element: <UsagePage /> },
        { path: 'plans', element: <PlansPage /> },
        { path: 'billing', element: <BillingPage /> },
        { path: 'membership', element: <MembershipPage /> },
        { path: 'support', element: <SupportPage /> },
        { path: 'support/:id', element: <SupportDetailPage /> },
        { path: 'settings', element: <ProfileSettingsPage /> },
      ],
    }],
  },
  {
    path: '/admin',
    element: <RequireAuth roles={ADMIN_ROLES} />,
    children: [{
      element: <AdminLayout />,
      children: [
        { index: true, element: <AdminDashboardPage /> },
        { path: 'settings', element: <ProfileSettingsPage /> },
        { path: 'incidents', element: <AdminIncidentsPage /> },
        { path: 'incidents/:id', element: <AdminIncidentDetailPage /> },
        { path: 'support', element: <AdminSupportPage /> },
        { path: 'support/:id', element: <AdminSupportPage /> },
        { path: 'customers', element: <AdminCustomersPage /> },
        { path: 'customers/:id', element: <AdminCustomerDetailPage /> },
        { path: 'payments', element: <AdminPaymentsPage /> },
        { path: 'benefits', element: <AdminBenefitsPage /> },
        { path: 'ip-blocks', element: <AdminIpBlocksPage /> },
        { path: 'privileges', element: <AdminPrivilegesPage /> },
        { path: 'automation', element: <AdminAutomationPage /> },
      ],
    }],
  },
  { path: '*', element: <Navigate to="/" replace /> },
])
