import { Link, useLocation, useParams } from 'react-router-dom'
import { useEffect, useState, type FormEvent } from 'react'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag, { paymentTone, ticketTone } from '../../components/common/Tag'
import type { CustomerDetail } from '../../services/types'
import { STATUS_LABEL, TICKET_STATUS, dataSize, dateTime, fullDate, won } from '../../utils/format'
import { useApi } from '../../utils/useApi'
import { api } from '../../services/apiClient'
import { customerMembershipName } from '../../utils/membership'

export default function AdminCustomerDetailPage() {
  const { id } = useParams()
  const { hash } = useLocation()
  const { loading, error, data, reload } = useApi<{ customer: CustomerDetail }>(`/admin/customers/${id}`)
  const tiers = useApi<{ tiers: { rank: number; name: string }[] }>('/admin/membership/tiers')
  const [rank, setRank] = useState('')
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null)
  useEffect(() => { if (data && hash === '#membership-tier') document.getElementById('membership-tier')?.scrollIntoView({ block: 'start' }) }, [data, hash])
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} />
  const c = data.customer
  const changeTier = async (e: FormEvent) => {
    e.preventDefault()
    if (busy || !reason.trim()) return
    const selectedRank = Math.min(Number(rank || c.membership?.rank || 0), 2)
    const label = tiers.data?.tiers.find(t => t.rank === selectedRank)?.name
    if (!window.confirm(`${c.name}님의 멤버십을 ${label} 등급으로 변경할까요?${!c.membership ? ' 미가입 회원은 포인트 0으로 가입됩니다.' : ''}`)) return
    setBusy(true); setMessage(null)
    try {
      await api(`/admin/membership/customers/${c.id}/tier`, { method: 'PATCH', body: { rank: selectedRank, reason: reason.trim() } })
      setMessage({ ok: true, text: '멤버십 등급을 변경했습니다.' }); setReason(''); setRank(''); reload()
    } catch (err) { setMessage({ ok: false, text: (err as Error).message }) }
    finally { setBusy(false) }
  }

  return (
    <section className="page">
      <Link to="/admin/customers" className="back">← 회원 목록</Link>
      <header className="page__header">
        <h1 className="page__title">{c.name}</h1>
        <Tag tone={c.is_active ? 'ok' : 'neutral'}>{c.is_active ? '이용 중' : '탈퇴'}</Tag>
      </header>
      <p className="muted page__lead">상세 정보 열람은 서버 로그에 기록됩니다.</p>

      <div className="grid grid--usage">
        <article className="panel">
          <h2>회원 정보</h2>
          <dl className="facts">
            <div><dt>이메일</dt><dd>{c.email}</dd></div>
            <div><dt>가입일</dt><dd>{fullDate(c.created_at)}</dd></div>
            <div><dt>최근 로그인</dt><dd>{dateTime(c.last_login_at)}</dd></div>
            <div><dt>요금제</dt><dd>{c.subscription ? `${c.subscription.plan.name} (${dataSize(c.subscription.plan.data_mb)})` : '없음'}</dd></div>
            <div><dt>회선 번호</dt><dd>{c.subscription?.phone_number ?? '-'}</dd></div>
            <div><dt>멤버십</dt><dd>{c.membership ? `${customerMembershipName(c.membership.tier, c.membership.rank)} · ${c.membership.point_balance.toLocaleString()}P` : '미가입'}</dd></div>
          </dl>
        </article>
        <article className="panel">
          <h2>미납 금액</h2>
          <p className="figure">{won(c.unpaid_amount)}</p>
          <p className="muted">포인트 잔액은 이 화면에서 바꿀 수 없습니다.</p>
        </article>
      </div>

      <article className="panel membership-tier-editor" id="membership-tier">
        <h2>멤버십 등급 조정</h2>
        <p className="muted">일반유저 / Plus / VIP 등급을 조정합니다. Admin은 관리자 역할이므로 멤버십으로 지정할 수 없습니다. 포인트 잔액은 유지하며, 미가입 회원을 지정하면 포인트 0으로 가입됩니다.</p>
        {tiers.error ? <ErrorState error={tiers.error} onRetry={tiers.reload} /> : <form className="form" onSubmit={changeTier}>
          <label>변경할 등급<select value={rank || String(Math.min(c.membership?.rank ?? 0, 2))} onChange={e => setRank(e.target.value)} disabled={busy || tiers.loading || !c.is_active}>{tiers.data?.tiers.filter(t => t.rank < 3).map(t => <option key={t.rank} value={t.rank}>{t.name}</option>)}</select></label>
          <label>변경 사유<input maxLength={300} required value={reason} onChange={e => setReason(e.target.value)} disabled={busy || !c.is_active} placeholder="등급 변경 사유를 입력하세요" /></label>
          <button className="btn" disabled={busy || tiers.loading || !tiers.data?.tiers.length || !c.is_active || !reason.trim()}>{busy ? '변경 중' : '등급 변경'}</button>
          {!c.is_active && <p className="muted">탈퇴한 회원은 등급을 변경할 수 없습니다.</p>}
        </form>}
        {message && <p className={message.ok ? 'form-ok' : 'form-error'} role="status">{message.text}</p>}
      </article>

      <div className="grid grid--2">
        <article className="panel">
          <h2>문의 내역</h2>
          {c.tickets.length === 0 ? <p className="muted">문의가 없습니다.</p> : (
            <ul className="list">
              {c.tickets.map((t) => (
                <li key={t.id}><Link to={`/admin/support/${t.id}`}>{t.title}</Link><Tag tone={ticketTone(t.status)}>{TICKET_STATUS[t.status]}</Tag></li>
              ))}
            </ul>
          )}
        </article>
        <article className="panel">
          <h2>청구서</h2>
          <ul className="list">
            {c.invoices.map((i) => (
              <li key={i.id}><span>{i.period} · {won(i.amount)}</span><Tag tone={paymentTone(i.status)}>{STATUS_LABEL[i.status]}</Tag></li>
            ))}
          </ul>
        </article>
      </div>

      <h2 className="section-title">결제 내역</h2>
      {c.payments.length === 0 ? <p className="muted">결제 내역이 없습니다.</p> : (
        <table className="table">
          <thead><tr><th>일시</th><th>청구월</th><th>거래번호</th><th>상태</th><th className="num">금액</th></tr></thead>
          <tbody>
            {c.payments.map((p) => (
              <tr key={p.id}><td>{dateTime(p.created_at)}</td><td>{p.period}</td><td className="mono">{p.transaction_ref}</td>
                <td><Tag tone={paymentTone(p.status)}>{STATUS_LABEL[p.status]}</Tag></td><td className="num">{won(p.amount)}</td></tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}
