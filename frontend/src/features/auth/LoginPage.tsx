import { useState, type FormEvent } from 'react'
import Logo from '../../components/common/Logo'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import { useAuth } from '../../app/providers/AuthProvider'

export default function LoginPage() {
  const { login } = useAuth()
  const navigate = useNavigate()
  const state = useLocation().state as { from?: string; notice?: string } | null
  const from = state?.from ?? '/'
  const [form, setForm] = useState({ email: '', password: '' })
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const onSubmit = async (e: FormEvent) => {
    e.preventDefault()
    if (!form.email || !form.password) { setError('이메일과 비밀번호를 입력하세요.'); return }
    setBusy(true); setError(null)
    try {
      const user = await login(form.email, form.password)
      navigate(user.role === 'CUSTOMER' ? from : '/admin', { replace: true })
    } catch (err) {
      setError((err as Error).message)
    } finally { setBusy(false) }
  }

  return (
    <div className="auth">
      <form className="auth__card" onSubmit={onSubmit} noValidate>
        <div className="brand"><Logo size="lg" /></div>
        <p className="auth__tagline">끊기지 않는 연결, 루프</p>
        <h1>로그인</h1>
        {state?.notice && <p className="form-ok" role="status">{state.notice}</p>}
        <label>이메일
          <input type="email" autoComplete="username" value={form.email}
                 onChange={(e) => setForm({ ...form, email: e.target.value })} />
        </label>
        <label>비밀번호
          <input type="password" autoComplete="current-password" value={form.password}
                 onChange={(e) => setForm({ ...form, password: e.target.value })} />
        </label>
        {error && <p className="form-error" role="alert">{error}</p>}
        <button className="btn" disabled={busy}>{busy ? '확인 중' : '로그인'}</button>
        <p className="muted">처음이신가요? <Link to="/register">회원가입</Link></p>
      </form>
    </div>
  )
}
