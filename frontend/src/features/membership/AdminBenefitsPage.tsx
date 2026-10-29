import { MEMBERSHIP_TIERS } from '../../utils/membership'
import { useState } from 'react'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag from '../../components/common/Tag'
import { ApiError, api } from '../../services/apiClient'
import type { BenefitPolicy } from '../../services/types'
import { useApi } from '../../utils/useApi'

const TIER = MEMBERSHIP_TIERS

// 멤버십 정책 관리 (관리자). 고객 포인트 잔액을 직접 바꾸는 기능은 일부러 없다.
export default function AdminBenefitsPage() {
  const { loading, error, data, reload } = useApi<{ benefits: BenefitPolicy[] }>('/admin/membership/benefits')
  const [drafts, setDrafts] = useState<Record<number, Partial<BenefitPolicy>>>({})
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} onRetry={reload} />

  const edit = (id: number, patch: Partial<BenefitPolicy>) => setDrafts({ ...drafts, [id]: { ...drafts[id], ...patch } })

  const save = async (b: BenefitPolicy) => {
    const change = drafts[b.id]
    if (!change) return
    try {
      await api(`/admin/membership/benefits/${b.id}`, { method: 'PATCH', body: change })
      const rest = { ...drafts }; delete rest[b.id]; setDrafts(rest)
      setMsg({ ok: true, text: `${b.name} 정책을 저장했습니다.` }); reload()
    } catch (err) {
      const ex = err as ApiError
      setMsg({ ok: false, text: ex.details ? Object.values(ex.details).join(' ') : ex.message })
    }
  }

  return (
    <section className="page">
      <h1 className="page__title">혜택 정책</h1>
      <p className="muted page__lead">필요 포인트·월 사용 횟수·최소 등급·노출 여부를 관리합니다. 고객 포인트 잔액은 여기서 바꿀 수 없습니다.</p>
      {msg && <div className={`notice ${msg.ok ? 'notice--ok' : 'notice--warn'}`}>{msg.text}</div>}
      <table className="table">
        <thead><tr><th>혜택</th><th>필요 포인트</th><th>월 횟수</th><th>최소 등급</th><th>상태</th><th /></tr></thead>
        <tbody>
          {data.benefits.map((b) => {
            const d = { ...b, ...drafts[b.id] }
            return (
              <tr key={b.id}>
                <td>{b.name}<div className="muted">{b.partner}</div></td>
                <td><input className="input--sm" type="number" min={100} step={100} value={d.required_points}
                           onChange={(e) => edit(b.id, { required_points: Number(e.target.value) })} /></td>
                <td><input className="input--sm" type="number" min={1} max={31} value={d.monthly_limit}
                           onChange={(e) => edit(b.id, { monthly_limit: Number(e.target.value) })} /></td>
                <td>
                  <select value={d.min_tier_rank} onChange={(e) => edit(b.id, { min_tier_rank: Number(e.target.value) })}>
                    {TIER.map((t, i) => <option key={t} value={i}>{t}</option>)}
                  </select>
                </td>
                <td>
                  <button type="button" className="chip" onClick={() => edit(b.id, { is_active: !d.is_active })}>
                    <Tag tone={d.is_active ? 'ok' : 'neutral'}>{d.is_active ? '노출 중' : '중지'}</Tag>
                  </button>
                </td>
                <td><button className="btn btn--sm" disabled={!drafts[b.id]} onClick={() => save(b)}>저장</button></td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </section>
  )
}
