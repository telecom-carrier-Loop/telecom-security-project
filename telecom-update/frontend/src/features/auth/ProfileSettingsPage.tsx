import { useEffect, useState, type ChangeEvent, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../../app/providers/AuthProvider'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Logo from '../../components/common/Logo'
import { ApiError, api } from '../../services/apiClient'
import type { Profile } from '../../services/types'
import { ROLE_LABEL, dateTime, fullDate } from '../../utils/format'
import { useApi } from '../../utils/useApi'

type Status = { type: 'ok' | 'error'; text: string } | null

// 폼 하나의 상태(값·필드 오류·결과 메시지·전송 중)를 묶어서 관리
function useForm<V extends Record<string, string>>(initial: V) {
  const [values, setValues] = useState<V>(initial)
  const [errors, setErrors] = useState<Record<string, string | undefined>>({})
  const [status, setStatus] = useState<Status>(null)
  const [busy, setBusy] = useState(false)
  const bind = (k: keyof V & string) => ({
    value: values[k],
    'aria-invalid': !!errors[k],
    onChange: (e: ChangeEvent<HTMLInputElement>) => {
      setValues({ ...values, [k]: e.target.value }); setErrors({ ...errors, [k]: undefined }); setStatus(null)
    },
  })
  async function run<R>(fn: (v: V) => Promise<R>, okText: string): Promise<R | null> {
    setBusy(true); setStatus(null)
    try {
      const result = await fn(values)
      setErrors({}); setStatus({ type: 'ok', text: okText })
      return result
    } catch (err) {
      const ex = err as ApiError
      setErrors(ex.details ?? {})
      if (!ex.details) setStatus({ type: 'error', text: ex.message })
      return null
    } finally { setBusy(false) }
  }
  return { values, setValues, errors, setErrors, status, busy, bind, run }
}

const FieldError = ({ text }: { text?: string }) => (text ? <span className="field-error">{text}</span> : null)
const StatusLine = ({ status }: { status: Status }) =>
  status ? <p className={status.type === 'ok' ? 'form-ok' : 'form-error'} role="status">{status.text}</p> : null

export default function ProfileSettingsPage() {
  const { setUser, forgetSession } = useAuth()
  const navigate = useNavigate()
  const { loading, error, data, reload } = useApi<{ user: Profile }>('/auth/me')
  const profile = data?.user

  const nameForm = useForm({ name: '' })
  const pwForm = useForm({ current_password: '', new_password: '', confirm: '' })
  const leaveForm = useForm({ password: '' })

  useEffect(() => { if (profile) nameForm.setValues({ name: profile.name }) }, [profile?.name]) // eslint-disable-line react-hooks/exhaustive-deps

  if (loading) return <Loading />
  if (error || !profile) return <ErrorState error={error} onRetry={reload} />

  const saveName = async (e: FormEvent) => {
    e.preventDefault()
    const res = await nameForm.run((v) => api<{ user: Profile }>('/auth/me', { method: 'PATCH', body: { name: v.name } }), '이름을 저장했습니다.')
    if (res) { setUser(res.user); reload() }
  }

  const changePassword = async (e: FormEvent) => {
    e.preventDefault()
    const v = pwForm.values
    if (v.new_password !== v.confirm) {
      pwForm.setErrors({ confirm: '새 비밀번호가 서로 다릅니다.' })
      return
    }
    const res = await pwForm.run(
      () => api('/auth/password', { method: 'POST', body: { current_password: v.current_password, new_password: v.new_password } }),
      '비밀번호를 변경했습니다.',
    )
    if (res) {
      // 서버가 모든 세션을 폐기했으므로 새 비밀번호로 다시 로그인
      forgetSession()
      navigate('/login', { replace: true, state: { notice: '비밀번호를 바꿨습니다. 새 비밀번호로 다시 로그인하세요.' } })
    }
  }

  const leave = async (e: FormEvent) => {
    e.preventDefault()
    if (!window.confirm('탈퇴하면 이 계정으로 다시 로그인할 수 없습니다. 계속할까요?')) return
    const res = await leaveForm.run((v) => api('/auth/deactivate', { method: 'POST', body: { password: v.password } }), '')
    if (res) { forgetSession(); navigate('/login', { replace: true }) }
  }

  return (
    <section className="page page--narrow">
      <h1 className="page__title">프로필 설정</h1>

      <article className="panel">
        <h2>계정 정보</h2>
        <dl className="facts">
          <div><dt>이메일</dt><dd>{profile.email}</dd></div>
          <div>
            <dt>계정 유형</dt>
            <dd>
              {profile.role !== 'CUSTOMER' ? ROLE_LABEL[profile.role]
                : profile.membership_joined ? <span className="member-badge"><Logo variant="plus" size="sm" /> 회원</span>
                  : <>일반 회원 <Link to="/membership" className="inline-link">L∞P+ 가입하기</Link></>}
            </dd>
          </div>
          <div><dt>가입일</dt><dd>{fullDate(profile.created_at)}</dd></div>
        </dl>
        <p className="muted">이메일은 로그인 아이디라서 바꿀 수 없습니다.</p>
      </article>

      <form className="panel form" onSubmit={saveName} noValidate>
        <h2>이름</h2>
        <label>표시 이름
          <input type="text" autoComplete="name" maxLength={50} {...nameForm.bind('name')} />
          <FieldError text={nameForm.errors.name} />
        </label>
        <StatusLine status={nameForm.status} />
        <button className="btn" disabled={nameForm.busy || nameForm.values.name === profile.name}>이름 저장</button>
      </form>

      <form className="panel form" onSubmit={changePassword} noValidate>
        <h2>비밀번호 변경</h2>
        <p className="muted">마지막 변경: {dateTime(profile.password_changed_at)} · 바꾸면 모든 기기에서 로그아웃됩니다.</p>
        <label>현재 비밀번호
          <input type="password" autoComplete="current-password" {...pwForm.bind('current_password')} />
          <FieldError text={pwForm.errors.current_password} />
        </label>
        <label>새 비밀번호 (영문+숫자 8자 이상)
          <input type="password" autoComplete="new-password" {...pwForm.bind('new_password')} />
          <FieldError text={pwForm.errors.new_password} />
        </label>
        <label>새 비밀번호 확인
          <input type="password" autoComplete="new-password" {...pwForm.bind('confirm')} />
          <FieldError text={pwForm.errors.confirm} />
        </label>
        <StatusLine status={pwForm.status} />
        <button className="btn" disabled={pwForm.busy || !pwForm.values.current_password || !pwForm.values.new_password}>
          비밀번호 변경
        </button>
      </form>

      <article className="panel">
        <h2>로그인 기록</h2>
        <dl className="facts">
          <div><dt>이전 로그인</dt><dd>{dateTime(profile.previous_login_at)}</dd></div>
          <div><dt>그 사이 로그인 실패</dt><dd>{profile.failed_attempts_before_login}회</dd></div>
        </dl>
        <p className="muted">15분 안에 비밀번호를 5번 틀리면 잠시 로그인이 제한됩니다.</p>
      </article>

      {profile.role === 'CUSTOMER' && (
        <form className="panel form panel--danger" onSubmit={leave} noValidate>
          <h2>회원 탈퇴</h2>
          <p className="muted">탈퇴해도 청구·결제 기록은 보관을 위해 남습니다.</p>
          <label>비밀번호 확인
            <input type="password" autoComplete="current-password" {...leaveForm.bind('password')} />
            <FieldError text={leaveForm.errors.password} />
          </label>
          <StatusLine status={leaveForm.status} />
          <button className="btn btn--danger" disabled={leaveForm.busy || !leaveForm.values.password}>회원 탈퇴</button>
        </form>
      )}
    </section>
  )
}
