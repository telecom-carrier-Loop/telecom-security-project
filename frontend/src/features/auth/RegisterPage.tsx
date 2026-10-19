import { useState, type ChangeEvent, type FormEvent } from 'react'
import Logo from '../../components/common/Logo'
import { Link, useNavigate } from 'react-router-dom'
import { ApiError, api } from '../../services/apiClient'

type Field = 'name' | 'email' | 'password'

export default function RegisterPage() {
  const navigate = useNavigate()
  const [form, setForm] = useState({ name: '', email: '', password: '' })
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [message, setMessage] = useState<string | null>(null)
  const set = (k: Field) => (e: ChangeEvent<HTMLInputElement>) => { setForm({ ...form, [k]: e.target.value }); setErrors({ ...errors, [k]: null }) }

  const onSubmit = async (e: FormEvent) => {
    e.preventDefault()
    setMessage(null)
    try {
      await api('/auth/register', { method: 'POST', body: form })
      navigate('/login', { replace: true })
    } catch (err) {
      const ex = err as ApiError
      setErrors(ex.details ?? {})
      setMessage(ex.message)
    }
  }

  return (
    <div className="auth">
      <form className="auth__card" onSubmit={onSubmit} noValidate>
        <div className="brand"><Logo size="lg" /></div>
        <h1>회원가입</h1>
        {([['name', '이름', 'text', 'name'], ['email', '이메일', 'email', 'username'],
          ['password', '비밀번호 (영문+숫자 8자 이상)', 'password', 'new-password']] as [Field, string, string, string][]).map(([k, label, type, ac]) => (
          <label key={k}>{label}
            <input type={type} autoComplete={ac} value={form[k]} onChange={set(k)} aria-invalid={!!errors[k]} />
            {errors[k] && <span className="field-error">{errors[k]}</span>}
          </label>
        ))}
        {message && !Object.values(errors).some(Boolean) && <p className="form-error" role="alert">{message}</p>}
        <button className="btn">가입하기</button>
        <p className="muted">이미 계정이 있나요? <Link to="/login">로그인</Link></p>
      </form>
    </div>
  )
}
