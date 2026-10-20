import { Link, useParams } from 'react-router-dom'
import ErrorState from '../../components/common/ErrorState'
import Loading from '../../components/common/Loading'
import Tag, { paymentTone, ticketTone } from '../../components/common/Tag'
import type { CustomerDetail } from '../../services/types'
import { STATUS_LABEL, TICKET_STATUS, dataSize, dateTime, fullDate, won } from '../../utils/format'
import { useApi } from '../../utils/useApi'

export default function AdminCustomerDetailPage() {
  const { id } = useParams()
  const { loading, error, data } = useApi<{ customer: CustomerDetail }>(`/admin/customers/${id}`)
  if (loading) return <Loading />
  if (error || !data) return <ErrorState error={error} />
  const c = data.customer

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
            <div><dt>멤버십</dt><dd>{c.membership ? `${c.membership.tier} · ${c.membership.point_balance.toLocaleString()}P` : '미가입'}</dd></div>
          </dl>
        </article>
        <article className="panel">
          <h2>미납 금액</h2>
          <p className="figure">{won(c.unpaid_amount)}</p>
          <p className="muted">포인트 잔액은 이 화면에서 바꿀 수 없습니다.</p>
        </article>
      </div>

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
