import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '../../app/providers/AuthProvider'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import { ApiError, api } from '../../services/apiClient'
import type { Plan } from '../../services/types'
import { dataSize, won } from '../../utils/format'
import { useApi } from '../../utils/useApi'

type Result = { type: 'ok' | 'error'; text: string } | null

// 요금제 카드를 누르면 아래에 상세와 비교, 변경(또는 가입) 버튼이 열린다.
export default function PlansPage() {
  const { user } = useAuth()
  const plans = useApi<{ plans: Plan[] }>('/plans')
  const mine = useApi<{ subscription: { plan: Plan; phone_number: string } | null }>('/subscriptions/me')
  const [selected, setSelected] = useState<Plan | null>(null)
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState<Result>(null)

  if (plans.loading || mine.loading) return <Loading />
  if (plans.error || !plans.data) return <ErrorState error={plans.error} onRetry={plans.reload} />
  const current = mine.data?.subscription?.plan ?? null
  const isCustomer = user?.role === 'CUSTOMER'

  const choose = async (plan: Plan) => {
    const verb = current ? '변경' : '가입'
    if (!window.confirm(`${plan.name} 요금제로 ${verb}할까요? (모의 처리로 바로 적용됩니다)`)) return
    setBusy(true); setResult(null)
    try {
      await api('/subscriptions/me', { method: 'POST', body: { plan_id: plan.id } })
      setResult({ type: 'ok', text: `${plan.name} 요금제로 ${verb}되었습니다. 다음 청구서부터 월 ${won(plan.monthly_fee)}이 적용됩니다.` })
      setSelected(null)
      mine.reload()
    } catch (err) {
      setResult({ type: 'error', text: (err as ApiError).message })
    } finally { setBusy(false) }
  }

  return (
    <section className="page">
      <h1 className="page__title">요금제</h1>
      <p className="page__lead muted">데이터는 얼마나, 요금은 얼마로? 내 생활에 맞는 요금제를 비교해 보세요.</p>
      {result && <div className={`notice ${result.type === 'ok' ? 'notice--ok' : 'notice--warn'}`} role="status">{result.text}</div>}
      {result?.type === 'ok' && <p className="muted"><Link to="/usage">내 이용현황에서 확인하기</Link></p>}

      <div className="plan-grid" role="list">
        {plans.data.plans.map((p) => {
          const isMine = p.id === current?.id
          const isSel = p.id === selected?.id
          return (
            <button key={p.id} type="button" role="listitem" aria-pressed={isSel}
                    className={`plan-card ${isMine ? 'plan-card--mine' : ''} ${isSel ? 'plan-card--selected' : ''}`}
                    onClick={() => setSelected(isSel ? null : p)}>
              <span className="plan-card__net">{p.network}</span>
              <span className="plan-card__name">{p.name}</span>
              <span className="plan-card__data">{dataSize(p.data_mb)}</span>
              <span className="plan-card__fee">월 {won(p.monthly_fee)}</span>
              {isMine && <span className="tag tag--info">사용 중</span>}
            </button>
          )
        })}
      </div>

      {selected && (
        <article className="panel plan-detail">
          <header className="panel__head">
            <h2>{selected.name}</h2>
            <button type="button" className="btn btn--ghost btn--sm" onClick={() => setSelected(null)}>닫기</button>
          </header>
          <table className="table compare">
            <thead><tr><th /><th>{current ? `지금 (${current.name})` : '지금'}</th><th>{selected.name}</th></tr></thead>
            <tbody>
              <tr><th>월 요금</th><td>{current ? won(current.monthly_fee) : '-'}</td><td>{won(selected.monthly_fee)}</td></tr>
              <tr><th>데이터</th><td>{current ? dataSize(current.data_mb) : '-'}</td><td>{dataSize(selected.data_mb)}</td></tr>
              <tr><th>음성통화</th><td>{current ? (current.voice_minutes < 0 ? '무제한' : `${current.voice_minutes}분`) : '-'}</td>
                <td>{selected.voice_minutes < 0 ? '무제한' : `${selected.voice_minutes}분`}</td></tr>
              <tr><th>망</th><td>{current?.network ?? '-'}</td><td>{selected.network}</td></tr>
            </tbody>
          </table>
          {current && (
            <p className="muted">
              월 요금이 {selected.monthly_fee >= current.monthly_fee
                ? `${won(selected.monthly_fee - current.monthly_fee)} 늘어납니다.`
                : `${won(current.monthly_fee - selected.monthly_fee)} 줄어듭니다.`}
            </p>
          )}
          {!isCustomer ? <p className="muted">관리자 계정은 요금제를 바꿀 수 없습니다.</p>
            : selected.id === current?.id ? <p className="muted">지금 사용 중인 요금제입니다.</p>
              : <button className="btn" disabled={busy} onClick={() => choose(selected)}>
                  {busy ? '처리 중' : current ? '이 요금제로 변경' : '이 요금제로 가입'}
                </button>}
        </article>
      )}
    </section>
  )
}
