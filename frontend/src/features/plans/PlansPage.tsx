import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import { dataSize, won } from '../../utils/format'
import type { Plan } from '../../services/types'
import { useApi } from '../../utils/useApi'

export default function PlansPage() {
  const plans = useApi<{ plans: Plan[] }>('/plans')
  const mine = useApi<{ subscription: { plan: Plan } | null }>('/subscriptions/me')
  if (plans.loading || mine.loading) return <Loading />
  if (plans.error || !plans.data) return <ErrorState error={plans.error} onRetry={plans.reload} />
  const myPlanId = mine.data?.subscription?.plan.id

  return (
    <section className="page">
      <h1 className="page__title">요금제</h1>
      <table className="table">
        <thead><tr><th>요금제</th><th>망</th><th>데이터</th><th className="num">월 요금</th><th /></tr></thead>
        <tbody>
          {plans.data.plans.map((p) => (
            <tr key={p.id} className={p.id === myPlanId ? 'is-mine' : ''}>
              <td>{p.name}</td><td>{p.network}</td><td>{dataSize(p.data_mb)}</td>
              <td className="num">{won(p.monthly_fee)}</td>
              <td>{p.id === myPlanId && <span className="tag">사용 중</span>}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}
