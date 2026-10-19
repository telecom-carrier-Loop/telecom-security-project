import type { Usage } from '../../services/types'
import { dataSize } from '../../utils/format'

const CELLS = 24

// 데이터 사용량을 신호 막대처럼 칸으로 보여준다. 남은 양이 주인공.
export default function DataMeter({ usage }: { usage: Usage | null }) {
  if (!usage) return <p className="muted">이번 달 사용량 집계가 아직 없습니다.</p>
  const unlimited = usage.data_limit_mb < 0
  const ratio = unlimited ? 0 : Math.min(usage.data_used_mb / usage.data_limit_mb, 1)
  const filled = Math.round(ratio * CELLS)
  const left = unlimited ? null : Math.max(usage.data_limit_mb - usage.data_used_mb, 0)
  const level = ratio >= 0.9 ? 'danger' : ratio >= 0.7 ? 'warn' : 'ok'

  return (
    <div className="meter">
      <p className="meter__headline">
        {unlimited || left === null ? '무제한' : <>{dataSize(left)}<small> 남음</small></>}
      </p>
      <div className={`meter__cells meter__cells--${level}`} role="img"
           aria-label={unlimited ? '무제한 요금제' : `${Math.round(ratio * 100)}% 사용`}>
        {Array.from({ length: CELLS }, (_, i) => (
          <span key={i} className={i < filled ? 'on' : ''} style={{ height: `${40 + (i / CELLS) * 60}%` }} />
        ))}
      </div>
      <p className="muted">{usage.period} · {dataSize(usage.data_used_mb)} 사용 / {dataSize(usage.data_limit_mb)}</p>
    </div>
  )
}
