import { Link } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import { dataSize, fullDate, won } from '../../utils/format'
import { useApi } from '../../utils/useApi'
import type { Plan, Usage } from '../../services/types'
import DataMeter from './DataMeter'

interface SubData { subscription: { id: number; phone_number: string; status: string; started_on: string; plan: Plan } | null }

// 내 이용현황: 회선 하나를 자세히 본다 (데이터·통화·요금제 정보)
export default function UsagePage() {
  const sub = useApi<SubData>('/subscriptions/me')
  const usage = useApi<{ usage: Usage | null }>('/usage/me')
  if (sub.loading || usage.loading) return <Loading />
  if (sub.error) return <ErrorState error={sub.error} onRetry={sub.reload} />

  if (!sub.data) return null
  const s = sub.data.subscription
  const u = usage.data?.usage
  if (!s) {
    return (
      <section className="page">
        <h1 className="page__title">내 이용현황</h1>
        <div className="panel"><p>가입한 회선이 없습니다.</p><Link className="btn" to="/plans">요금제 둘러보기</Link></div>
      </section>
    )
  }
  const voiceLimit = u?.voice_limit_minutes ?? -1

  return (
    <section className="page">
      <h1 className="page__title">내 이용현황</h1>
      <p className="page__lead muted">나의 회선과 이번 달 데이터·통화 사용량을 확인하세요.</p>
      <div className="grid grid--usage">
        <article className="panel panel--hero">
          <header className="panel__head"><h2>데이터</h2><span className="muted">{s.phone_number}</span></header>
          <DataMeter usage={u ?? null} />
        </article>
        <article className="panel">
          <h2>음성통화</h2>
          <p className="figure">{u ? `${u.voice_used_minutes}분` : '-'}</p>
          <p className="muted">{voiceLimit < 0 ? '기본 제공 무제한' : `${voiceLimit}분 제공`}</p>
        </article>
      </div>

      <article className="panel">
        <header className="panel__head"><h2>가입 요금제</h2><Link to="/plans">다른 요금제 보기</Link></header>
        <dl className="facts">
          <div><dt>요금제</dt><dd>{s.plan.name}</dd></div>
          <div><dt>월 요금</dt><dd>{won(s.plan.monthly_fee)}</dd></div>
          <div><dt>기본 데이터</dt><dd>{dataSize(s.plan.data_mb)}</dd></div>
          <div><dt>망</dt><dd>{s.plan.network}</dd></div>
          <div><dt>회선 번호</dt><dd>{s.phone_number}</dd></div>
          <div><dt>개통일</dt><dd>{fullDate(s.started_on)}</dd></div>
        </dl>
      </article>
    </section>
  )
}
