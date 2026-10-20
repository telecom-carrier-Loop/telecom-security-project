import { useState } from 'react'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag from '../../components/common/Tag'
import { ApiError, api } from '../../services/apiClient'
import type { PrivilegeData } from '../../services/types'
import { dateTime } from '../../utils/format'
import { useApi } from '../../utils/useApi'

// 권한 점검: 허용목록(ADMIN_ALLOWLIST) 밖 관리자를 찾아 회수한다.
// 웹에서는 회수만 가능하고, 관리자 부여는 서버 명령(python -m flask --app wsgi grant-admin)으로만 한다.
export default function AdminPrivilegesPage() {
  const { loading, error, data, reload } = useApi<PrivilegeData>('/admin/privileges')
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} onRetry={reload} />

  const revoke = async (id: number, name: string) => {
    const reason = window.prompt(`${name}님의 관리자 권한을 회수합니다. 일반 회원이 되고 로그인 세션이 끊깁니다. 사유를 입력하세요.`, '과잉 권한 회수')
    if (reason === null) return
    try { await api(`/admin/users/${id}/revoke-admin`, { method: 'POST', body: { reason } }); setMsg({ ok: true, text: '권한을 회수했습니다.' }); reload() }
    catch (err) { setMsg({ ok: false, text: (err as ApiError).message }) }
  }

  return (
    <section className="page page--wide">
      <h1 className="page__title">권한 점검</h1>
      {!data.allowlist_configured ? (
        <div className="notice notice--warn">허용목록이 설정되지 않았습니다. 서버 <span className="mono">.env</span>의 <span className="mono">ADMIN_ALLOWLIST</span>에 관리자 이메일을 쉼표로 넣으면 점검과 자동 회수가 동작합니다.</div>
      ) : data.violations > 0 ? (
        <div className="notice notice--danger" role="alert">정책 위반 — 허용목록 밖 관리자 {data.violations}명. 의도한 계정이 아니라면 회수하세요.</div>
      ) : (
        <div className="notice notice--ok">모든 관리자가 허용목록 안에 있습니다. (허용목록 {data.allowlist_size}명)</div>
      )}
      {msg && <div className={`notice ${msg.ok ? 'notice--ok' : 'notice--warn'}`} role="status">{msg.text}</div>}

      <table className="table">
        <thead><tr><th>이름</th><th>이메일</th><th>허용목록</th><th>마지막 로그인</th><th>등록일</th><th /></tr></thead>
        <tbody>
          {data.admins.map((a) => (
            <tr key={a.id} className={a.in_allowlist === false ? 'row--locked' : ''}>
              <td>{a.name}{a.is_self && <span className="muted"> (나)</span>}</td>
              <td className="mono">{a.email}</td>
              <td>{a.in_allowlist === null ? <span className="muted">미설정</span>
                : <Tag tone={a.in_allowlist ? 'ok' : 'danger'}>{a.in_allowlist ? '허용' : '위반'}</Tag>}</td>
              <td>{dateTime(a.last_login_at)}</td>
              <td>{dateTime(a.created_at)}</td>
              <td>{!a.is_self && <button className="btn btn--sm btn--danger" onClick={() => revoke(a.id, a.name)}>회수</button>}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="muted">본인과 마지막 관리자는 회수할 수 없습니다. 1-자동 회수 봇은 허용목록 밖 관리자만 회수합니다.</p>
    </section>
  )
}
