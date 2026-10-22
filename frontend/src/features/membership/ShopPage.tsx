import { useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag from '../../components/common/Tag'
import { ApiError, api } from '../../services/apiClient'
import type { ShopItem, ShopOrder } from '../../services/types'
import { compactDateTime } from '../../utils/format'
import { newIdempotencyKey } from '../../utils/idempotency'
import { useApi } from '../../utils/useApi'

const TIER_NAME = ['Basic', 'Silver', 'Gold', 'VIP']
const CAT_LABEL: Record<string, string> = { GOODS: '상품', DATA: '데이터', COUPON: '쿠폰' }

// L∞P+ 포인트 상점: 등급별로 교환할 수 있는 상품이 다르다
export default function ShopPage() {
  const shop = useApi<{ items: ShopItem[]; balance: number | null; tier: { name: string; rank: number } | null }>('/membership/shop')
  const orders = useApi<{ orders: ShopOrder[] }>('/membership/shop/orders')
  const [busy, setBusy] = useState<number | null>(null)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const keys = useRef<Record<number, string>>({})
  if (shop.loading) return <Loading />
  if (shop.error || !shop.data) return <ErrorState error={shop.error} onRetry={shop.reload} />
  const { items, balance, tier } = shop.data

  const buy = async (item: ShopItem) => {
    if (!window.confirm(`${item.name}을(를) ${item.price_points.toLocaleString()}P로 교환할까요?`)) return
    keys.current[item.id] ??= newIdempotencyKey()   // 결과를 모르는 재시도에는 같은 키
    setBusy(item.id); setMsg(null)
    try {
      const d = await api<{ order: ShopOrder; balance?: number }>(`/membership/shop/${item.id}/purchase`, {
        method: 'POST', headers: { 'Idempotency-Key': keys.current[item.id] } })
      setMsg({ ok: true, text: `교환 완료 — 교환 코드 ${d.order.code}` })
      delete keys.current[item.id]
      shop.reload(); orders.reload()
    } catch (err) {
      const e = err as ApiError
      if (e.status !== 0 && e.status < 500) delete keys.current[item.id]
      setMsg({ ok: false, text: e.message })
    } finally { setBusy(null) }
  }

  return (
    <section className="page">
      <header className="page__header">
        <h1 className="page__title">포인트 상점</h1>
        {balance !== null && <span className="figure">{balance.toLocaleString()}P</span>}
      </header>
      {tier ? <p className="muted">현재 등급 <strong>{tier.name}</strong> · 등급이 높을수록 교환할 수 있는 상품이 많아집니다.</p>
        : <div className="notice notice--warn">L∞P+ 멤버십에 가입하면 포인트로 상품을 교환할 수 있습니다. <Link to="/membership">가입하기</Link></div>}
      {msg && <div className={`notice ${msg.ok ? 'notice--ok' : 'notice--warn'}`} role="status">{msg.text}</div>}

      <div className="shop-grid">
        {items.map((i) => {
          const locked = tier !== null && tier.rank < i.min_tier_rank
          return (
            <article key={i.id} className={`panel shop-card ${locked || i.sold_out ? 'shop-card--off' : ''}`}>
              <div className="row"><Tag tone="info">{CAT_LABEL[i.category]}</Tag>{i.min_tier_rank > 0 && <Tag tone="neutral">{TIER_NAME[i.min_tier_rank]} 이상</Tag>}</div>
              <h2 className="shop-card__name">{i.name}</h2>
              <p className="muted">{i.description}</p>
              <div className="shop-card__foot">
                <span className="figure">{i.price_points.toLocaleString()}P</span>
                <span className="muted">{i.stock === null ? '' : i.sold_out ? '품절' : `남은 수량 ${i.stock}`}</span>
              </div>
              <button className="btn" disabled={!tier || !i.available || busy === i.id || (balance ?? 0) < i.price_points}
                      onClick={() => buy(i)}>
                {busy === i.id ? '교환 중' : locked ? `${TIER_NAME[i.min_tier_rank]} 등급부터` : i.sold_out ? '품절' :
                  (balance ?? 0) < i.price_points ? '포인트 부족' : '교환하기'}
              </button>
            </article>
          )
        })}
      </div>

      <h2 className="section-title">교환 내역</h2>
      {(orders.data?.orders ?? []).length === 0 ? <p className="muted">아직 교환한 상품이 없습니다.</p> : (
        <table className="table">
          <thead><tr><th>일시</th><th>상품</th><th className="num">포인트</th><th>교환 코드</th></tr></thead>
          <tbody>{orders.data!.orders.map((o) => (
            <tr key={o.id}><td>{compactDateTime(o.created_at)}</td><td>{o.item}</td><td className="num">-{o.points.toLocaleString()}</td><td className="mono">{o.code}</td></tr>
          ))}</tbody>
        </table>
      )}
    </section>
  )
}
