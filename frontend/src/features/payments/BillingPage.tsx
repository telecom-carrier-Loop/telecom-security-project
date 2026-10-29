import { useRef, useState, type FormEvent } from 'react'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag, { paymentTone } from '../../components/common/Tag'
import { ApiError, api } from '../../services/apiClient'
import type { Invoice, Payment } from '../../services/types'
import { STATUS_LABEL, dateTime, fullDate, won } from '../../utils/format'
import { newIdempotencyKey } from '../../utils/idempotency'
import { useApi } from '../../utils/useApi'

type Result = { type: 'ok' | 'error'; text: string } | null

const methodLabel = (m: string) => (m === 'KAKAOPAY' ? '카카오페이 (테스트)' : m.startsWith('MOCK_CARD_') ? `테스트 카드 ··${m.slice(10)}` : '테스트 카드')

export default function BillingPage() {
  const invoices = useApi<{ invoices: Invoice[] }>('/invoices/me')
  const payments = useApi<{ payments: Payment[] }>('/payments/me')
  const cards = useApi<{ cards: { number: string; result: string }[] }>('/payments/test-cards')
  const [paying, setPaying] = useState<Invoice | null>(null)
  const [card, setCard] = useState('4242424242424242')
  const [result, setResult] = useState<Result>(null)
  const [busy, setBusy] = useState(false)
  const keyRef = useRef<string>('')

  if (invoices.loading || payments.loading || cards.loading) return <Loading />
  if (invoices.error || !invoices.data) return <ErrorState error={invoices.error} onRetry={invoices.reload} />

  const open = (inv: Invoice) => { setPaying(inv); setResult(null); keyRef.current = newIdempotencyKey() }

  const kakaoPay = () => window.alert('결제 시스템은 준비중 입니다.')

  const pay = async (e: FormEvent) => {
    e.preventDefault()
    if (!paying) return
    setBusy(true)
    try {
      // 금액은 보내지 않는다. 서버가 청구서 금액으로 결제한다.
      const d = await api<{ payment: Payment }>('/payments', {
        method: 'POST', headers: { 'Idempotency-Key': keyRef.current },
        body: { invoice_id: paying.id, card_number: card },
      })
      const p = d.payment
      setResult(p.status === 'SUCCEEDED'
        ? { type: 'ok', text: `${won(p.amount)} 결제가 완료되었습니다. (거래번호 ${p.transaction_ref})` }
        : { type: 'error', text: p.events?.at(-1)?.detail ?? '결제가 승인되지 않았습니다.' })
      if (p.status === 'SUCCEEDED') setPaying(null)
      keyRef.current = newIdempotencyKey() // 결과가 확정됐으니 다음 시도는 새 결제
      invoices.reload(); payments.reload()
    } catch (err) {
      const ex = err as ApiError
      setResult({ type: 'error', text: ex.message })
      // 결과를 모르는 경우(네트워크·5xx)는 같은 키로 다시 눌러야 중복 결제가 생기지 않는다
      if (ex.status !== 0 && ex.status < 500) keyRef.current = newIdempotencyKey()
    } finally { setBusy(false) }
  }

  const list = invoices.data.invoices
  const due = list.filter((i) => i.status === 'UNPAID' || i.status === 'OVERDUE')
  return (
    <section className="page">
      <h1 className="page__title">요금 납부</h1>
      <p className="page__lead muted">청구 내역부터 납부 결과까지 한곳에서 확인하세요. 결제는 테스트용입니다.</p>

      {result && <div className={`notice ${result.type === 'ok' ? 'notice--ok' : 'notice--warn'}`} role="status">{result.text}</div>}

      {due.length === 0 && <div className="panel panel--muted"><p className="muted">납부할 요금이 없습니다.</p></div>}
      {due.map((inv) => (
        <article key={inv.id} className="panel bill">
          <div className="bill__info">
            <span className="muted">{inv.period} 청구</span>
            <span className="figure">{won(inv.amount)}</span>
            <span className="muted">{fullDate(inv.due_date)}까지 · <Tag tone={paymentTone(inv.status)}>{STATUS_LABEL[inv.status]}</Tag></span>
          </div>
          {paying?.id === inv.id ? (
            <form className="bill__form" onSubmit={pay}>
              <label>테스트 카드
                <select value={card} onChange={(e) => setCard(e.target.value)}>
                  {(cards.data?.cards ?? []).map((c) => (
                    <option key={c.number} value={c.number}>{c.number.replace(/(\d{4})(?=\d)/g, '$1 ')} · {c.result}</option>
                  ))}
                </select>
              </label>
              <div className="row">
                <button className="btn" disabled={busy}>{busy ? '결제 중' : `${won(inv.amount)} 결제`}</button>
                <button type="button" className="btn btn--ghost" onClick={() => setPaying(null)}>취소</button>
              </div>
              <p className="muted">모의 결제입니다. 실제 카드 정보를 입력하지 마세요.</p>
            </form>
          ) : (
            <div className="row">
              <button className="btn" onClick={() => open(inv)}>테스트 카드로 납부</button>
              <button type="button" className="btn btn--kakao" disabled={busy} onClick={kakaoPay}>카카오페이</button>
            </div>
          )}
        </article>
      ))}

      <h2 className="section-title">청구 내역</h2>
      <table className="table">
        <thead><tr><th>청구월</th><th>납기일</th><th>상태</th><th className="num">금액</th></tr></thead>
        <tbody>
          {list.map((i) => (
            <tr key={i.id}><td>{i.period}</td><td>{fullDate(i.due_date)}</td>
              <td><Tag tone={paymentTone(i.status)}>{STATUS_LABEL[i.status]}</Tag></td><td className="num">{won(i.amount)}</td></tr>
          ))}
        </tbody>
      </table>

      <h2 className="section-title">결제 내역</h2>
      <table className="table">
        <thead><tr><th>일시</th><th>청구월</th><th>결제수단</th><th>상태</th><th className="num">금액</th></tr></thead>
        <tbody>
          {(payments.data?.payments ?? []).map((p) => (
            <tr key={p.id}><td>{dateTime(p.created_at)}</td><td>{p.period}</td><td>{methodLabel(p.method)}</td>
              <td><Tag tone={paymentTone(p.status)}>{STATUS_LABEL[p.status]}</Tag></td><td className="num">{won(p.amount)}</td></tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}
