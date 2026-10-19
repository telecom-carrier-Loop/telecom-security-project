import type { Ticket } from '../../services/types'
import { dateTime } from '../../utils/format'

// 문의 본문 + 답변. 텍스트는 React가 이스케이프하므로 <script>가 그대로 글자로 보인다.
export default function TicketThread({ ticket, customerLabel = '나' }: { ticket: Ticket; customerLabel?: string }) {
  return (
    <div className="thread">
      <article className="bubble">
        <header><strong>{customerLabel}</strong><span className="muted">{dateTime(ticket.created_at)}</span></header>
        <p className="prewrap">{ticket.content}</p>
      </article>
      {ticket.replies.map((r) => (
        <article key={r.id} className="bubble bubble--reply">
          <header><strong>{r.author}</strong><span className="muted">{dateTime(r.created_at)}</span></header>
          <p className="prewrap">{r.content}</p>
        </article>
      ))}
    </div>
  )
}
