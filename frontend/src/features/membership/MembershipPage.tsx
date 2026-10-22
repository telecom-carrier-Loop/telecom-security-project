import { Link } from 'react-router-dom'
import { useRef, useState } from 'react'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Logo from '../../components/common/Logo'
import { ApiError, api } from '../../services/apiClient'
import type { Benefit, Membership, PointTransaction, Redemption } from '../../services/types'
import { dateTime, won } from '../../utils/format'
import { newIdempotencyKey } from '../../utils/idempotency'
import { useApi } from '../../utils/useApi'

const KIND: Record<string, string> = { EARN: '적립', REDEEM: '사용', REVERSE: '취소' }
type Message = { type: 'ok' | 'error'; text: string } | null

export default function MembershipPage() {
  const me = useApi<{ membership: Membership }>('/membership/me')
  const benefits = useApi<{ benefits: Benefit[] }>('/membership/benefits')
  const tx = useApi<{ transactions: PointTransaction[] }>('/membership/transactions')
  const used = useApi<{ redemptions: Redemption[] }>('/membership/redemptions')
  const [message, setMessage] = useState<Message>(null)
  const [busyId, setBusyId] = useState<number | null>(null)
  const keys = useRef<Record<number, string>>({}) // 혜택별 재시도용 키

  if (me.loading || benefits.loading) return <Loading />
  if (me.error || !me.data) return <ErrorState error={me.error} onRetry={me.reload} />
  const m = me.data.membership
  const reloadAll = () => { me.reload(); benefits.reload(); tx.reload(); used.reload() }

  const join = async () => {
    try { await api('/membership/join', { method: 'POST' }); reloadAll() }
    catch (err) { setMessage({ type: 'error', text: (err as ApiError).message }) }
  }

  const redeem = async (b: Benefit) => {
    if (!window.confirm(`${b.name}에 ${b.required_points.toLocaleString()}P를 사용할까요?`)) return
    keys.current[b.id] ??= newIdempotencyKey()
    setBusyId(b.id); setMessage(null)
    try {
      const d = await api<{ redemption: Redemption }>(`/membership/benefits/${b.id}/redeem`, {
        method: 'POST', headers: { 'Idempotency-Key': keys.current[b.id] },
      })
      delete keys.current[b.id] // 성공했으니 다음 사용은 새 키
      setMessage({ type: 'ok', text: `사용 완료 · 쿠폰 번호 ${d.redemption.code}` })
      reloadAll()
    } catch (err) {
      const ex = err as ApiError
      // 결과를 모르는 경우(네트워크·5xx)만 같은 키로 재시도, 나머지는 새 요청
      if (ex.status !== 0 && ex.status < 500) delete keys.current[b.id]
      setMessage({ type: 'error', text: ex.message })
    } finally { setBusyId(null) }
  }

  if (!m.joined) {
    return (
      <section className="page page--narrow">
        <h1 className="page__title"><Logo variant="plus" size="md" /> 멤버십</h1>
        <article className="panel join">
          <h2>L∞P+ 회원이 되면</h2>
          <ul className="checklist">
            <li>가입 즉시 1,000P 적립</li>
            <li>요금을 낼 때마다 납부 금액의 1% 적립</li>
            <li>편의점·카페·영화 제휴 혜택을 포인트로 사용</li>
          </ul>
          <p className="muted">등급은 가입한 요금제의 월 요금으로 정해집니다. 가입비는 없습니다.</p>
          {message && <p className="form-error">{message.text}</p>}
          <button className="btn" onClick={join}>무료로 가입하기</button>
        </article>
      </section>
    )
  }

  return (
    <section className="page">
      <h1 className="page__title"><Logo variant="plus" size="md" /> 멤버십</h1>
      <div className="grid grid--usage">
        <article className="panel panel--hero">
          <h2>사용 가능한 포인트</h2>
          <p className="meter__headline">{m.point_balance.toLocaleString()}<small>P</small></p>
          <p className="muted">{m.tier.name} 등급 · 요금 납부 시 <strong>{m.tier.earn_rate_bp / 100}%</strong> 적립
            {m.next_tier && ` · 월 ${won(m.next_tier.min_monthly_fee)} 이상 요금제면 ${m.next_tier.name}`}</p>
          <p><Link to="/membership/shop">포인트 상점 가기 →</Link></p>
        </article>
        <article className="panel">
          <h2>등급별 적립률</h2>
          <table className="table">
            <thead><tr><th>등급</th><th>조건 (월 요금)</th><th className="num">납부 적립</th></tr></thead>
            <tbody>{m.tiers.map((t) => (
              <tr key={t.rank} className={t.rank === m.tier.rank ? 'row--current' : ''}>
                <td>{t.name}{t.rank === m.tier.rank && ' (현재)'}</td>
                <td>{t.min_monthly_fee ? `${won(t.min_monthly_fee)} 이상` : '누구나'}</td>
                <td className="num">{t.earn_rate_bp / 100}%</td>
              </tr>
            ))}</tbody>
          </table>
        </article>
        <article className="panel">
          <h2>최근 사용한 혜택</h2>
          {used.data?.redemptions.length ? (
            <ul className="list">
              {used.data.redemptions.slice(0, 4).map((r) => (
                <li key={r.id}><span>{r.benefit}</span><span className="mono">{r.code}</span></li>
              ))}
            </ul>
          ) : <p className="muted">아직 사용한 혜택이 없습니다.</p>}
        </article>
      </div>

      {message && <div className={`notice ${message.type === 'ok' ? 'notice--ok' : 'notice--warn'}`} role="status">{message.text}</div>}

      <h2 className="section-title">혜택</h2>
      <div className="cards">
        {(benefits.data?.benefits ?? []).map((b) => (
          <article key={b.id} className={`card ${b.available ? '' : 'card--off'}`}>
            <span className="muted">{b.partner}</span>
            <strong>{b.name}</strong>
            <span className="card__points">{b.required_points.toLocaleString()}P</span>
            <span className="muted">월 {b.monthly_limit}회 · 이번 달 {b.used_this_month}회 사용</span>
            <button className="btn" disabled={!b.available || busyId === b.id} onClick={() => redeem(b)}>
              {b.available ? (busyId === b.id ? '처리 중' : '사용하기') : b.unavailable_reason}
            </button>
          </article>
        ))}
      </div>

      <h2 className="section-title">포인트 내역</h2>
      <table className="table">
        <thead><tr><th>일시</th><th>내용</th><th>구분</th><th className="num">포인트</th><th className="num">잔액</th></tr></thead>
        <tbody>
          {(tx.data?.transactions ?? []).map((t) => (
            <tr key={t.id}>
              <td>{dateTime(t.created_at)}</td><td>{t.memo}</td><td>{KIND[t.kind] ?? t.kind}</td>
              <td className={`num ${t.amount < 0 ? 'minus' : 'plus'}`}>{t.amount > 0 ? '+' : ''}{t.amount.toLocaleString()}</td>
              <td className="num">{t.balance_after.toLocaleString()}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}
