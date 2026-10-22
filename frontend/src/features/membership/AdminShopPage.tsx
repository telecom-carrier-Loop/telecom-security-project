import { useState, type FormEvent } from 'react'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag from '../../components/common/Tag'
import { ApiError, api } from '../../services/apiClient'
import type { ShopItem } from '../../services/types'
import { useApi } from '../../utils/useApi'

const TIERS = ['Basic', 'Silver', 'Gold', 'VIP']
const EMPTY = { name: '', description: '', category: 'GOODS', price_points: 1000, stock: '', min_tier_rank: 0 }

// 포인트 상점 상품 관리 (잔액 직접 수정 기능은 두지 않는다)
export default function AdminShopPage() {
  const { loading, error, data, reload } = useApi<{ items: ShopItem[] }>('/admin/membership/shop-items')
  const [form, setForm] = useState(EMPTY)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} onRetry={reload} />
  const fail = (err: unknown) => { const e = err as ApiError; setMsg({ ok: false, text: e.details ? Object.values(e.details).join(' ') : e.message }) }

  const create = async (e: FormEvent) => {
    e.preventDefault()
    try {
      await api('/admin/membership/shop-items', { method: 'POST', body: {
        ...form, price_points: Number(form.price_points), min_tier_rank: Number(form.min_tier_rank),
        stock: form.stock === '' ? null : Number(form.stock) } })
      setForm(EMPTY); setMsg({ ok: true, text: '상품을 추가했습니다.' }); reload()
    } catch (err) { fail(err) }
  }
  const patch = async (i: ShopItem, body: Record<string, unknown>) => {
    try { await api(`/admin/membership/shop-items/${i.id}`, { method: 'PATCH', body }); reload() } catch (err) { fail(err) }
  }
  const editNumber = (i: ShopItem, key: 'price_points' | 'stock', label: string) => {
    const v = window.prompt(`${i.name} ${label} (재고는 비우면 무제한)`, String(i[key] ?? ''))
    if (v === null) return
    patch(i, { [key]: key === 'stock' && v.trim() === '' ? null : Number(v) })
  }

  return (
    <section className="page page--wide">
      <h1 className="page__title">포인트 상점 관리</h1>
      {msg && <div className={`notice ${msg.ok ? 'notice--ok' : 'notice--warn'}`} role="status">{msg.text}</div>}
      <form className="panel inline-form" onSubmit={create}>
        <input className="grow" placeholder="상품명" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} required />
        <input className="grow" placeholder="설명 (선택)" value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} />
        <select value={form.category} onChange={(e) => setForm({ ...form, category: e.target.value })} aria-label="분류">
          <option value="GOODS">상품</option><option value="DATA">데이터</option><option value="COUPON">쿠폰</option>
        </select>
        <input type="number" min={1} aria-label="가격(포인트)" value={form.price_points} onChange={(e) => setForm({ ...form, price_points: Number(e.target.value) })} />
        <input type="number" min={0} placeholder="재고(빈칸=무제한)" aria-label="재고" value={form.stock} onChange={(e) => setForm({ ...form, stock: e.target.value })} />
        <select value={form.min_tier_rank} onChange={(e) => setForm({ ...form, min_tier_rank: Number(e.target.value) })} aria-label="최소 등급">
          {TIERS.map((t, i) => <option key={t} value={i}>{t} 이상</option>)}
        </select>
        <button className="btn">추가</button>
      </form>
      <div className="table-wrap">
        <table className="table table--compact">
          <thead><tr><th>상품</th><th>등급</th><th className="num">가격</th><th className="num">재고</th><th className="num">판매</th><th>상태</th><th>동작</th></tr></thead>
          <tbody>{data.items.map((i) => (
            <tr key={i.id}>
              <td className="wrap"><strong>{i.name}</strong><div className="muted">{i.description}</div></td>
              <td>{TIERS[i.min_tier_rank]} 이상</td>
              <td className="num">{i.price_points.toLocaleString()}P</td>
              <td className="num">{i.stock ?? '무제한'}</td>
              <td className="num">{i.sold ?? 0}</td>
              <td><Tag tone={i.is_active ? 'ok' : 'neutral'}>{i.is_active ? '판매 중' : '중지'}</Tag></td>
              <td><div className="row">
                <button className="btn btn--sm btn--ghost" onClick={() => editNumber(i, 'price_points', '가격')}>가격</button>
                <button className="btn btn--sm btn--ghost" onClick={() => editNumber(i, 'stock', '재고')}>재고</button>
                <button className="btn btn--sm btn--ghost" onClick={() => patch(i, { is_active: !i.is_active })}>{i.is_active ? '판매 중지' : '판매 재개'}</button>
              </div></td>
            </tr>
          ))}</tbody>
        </table>
      </div>
    </section>
  )
}
