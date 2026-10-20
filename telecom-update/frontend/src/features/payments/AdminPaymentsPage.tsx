import { useState } from 'react'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag, { paymentTone } from '../../components/common/Tag'
import { ApiError, api } from '../../services/apiClient'
import type { Payment } from '../../services/types'
import { STATUS_LABEL, dateTime, won } from '../../utils/format'
import { useApi } from '../../utils/useApi'

export default function AdminPaymentsPage() {
  const { loading, error, data, reload } = useApi<{ payments: Payment[] }>('/admin/payments')
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} onRetry={reload} />

  const refund = async (p: Payment) => {
    const reason = window.prompt(`${p.customer_name}님 ${won(p.amount)} 결제를 환불합니다. 사유를 입력하세요.`)
    if (!reason) return
    try { await api(`/admin/payments/${p.id}/refund`, { method: 'POST', body: { reason } }); setMsg({ ok: true, text: '모의 환불을 처리했습니다. 적립됐던 포인트도 함께 취소됩니다.' }); reload() }
    catch (err) { const ex = err as ApiError; setMsg({ ok: false, text: ex.details?.reason ?? ex.message }) }
  }

  return (
    <section className="page">
      <h1 className="page__title">결제 관리</h1>
      {msg && <div className={`notice ${msg.ok ? 'notice--ok' : 'notice--warn'}`}>{msg.text}</div>}
      <table className="table">
        <thead><tr><th>일시</th><th>고객</th><th>청구월</th><th>거래번호</th><th>상태</th><th className="num">금액</th><th /></tr></thead>
        <tbody>
          {data.payments.map((p) => (
            <tr key={p.id}>
              <td>{dateTime(p.created_at)}</td><td>{p.customer_name}</td><td>{p.period}</td>
              <td className="mono">{p.transaction_ref}</td>
              <td><Tag tone={paymentTone(p.status)}>{STATUS_LABEL[p.status]}</Tag></td>
              <td className="num">{won(p.amount)}</td>
              <td>{p.status === 'SUCCEEDED' && <button className="btn btn--ghost btn--sm" onClick={() => refund(p)}>환불</button>}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}
