import { useEffect, useRef, useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router-dom'
import Loading from '../../components/common/Loading'
import { ApiError, api } from '../../services/apiClient'

// 카카오페이 인증 후 돌아오는 화면: /billing/kakaopay/approve|cancel|fail?payment_id=..&pg_token=..
export default function KakaoPayResultPage() {
  const { result } = useParams()
  const [params] = useSearchParams()
  const [state, setState] = useState<{ ok: boolean; text: string } | null>(null)
  const sent = useRef(false)

  useEffect(() => {
    if (sent.current) return            // 개발 모드 이중 실행 방지 (서버도 같은 결과를 돌려줌)
    sent.current = true
    const paymentId = Number(params.get('payment_id'))
    const run = async () => {
      try {
        if (result === 'approve') {
          await api('/payments/kakaopay/approve', { method: 'POST', body: { payment_id: paymentId, pg_token: params.get('pg_token') ?? '' } })
          setState({ ok: true, text: '카카오페이 결제가 완료되었습니다.' })
        } else {
          await api('/payments/kakaopay/abort', { method: 'POST', body: { payment_id: paymentId, reason: result === 'cancel' ? 'cancel' : 'fail' } })
          setState({ ok: false, text: result === 'cancel' ? '결제를 취소했습니다.' : '카카오페이 결제에 실패했습니다.' })
        }
      } catch (err) {
        setState({ ok: false, text: (err as ApiError).message })
      }
    }
    run()
  }, [params, result])

  return (
    <section className="page">
      <h1 className="page__title">카카오페이 결제</h1>
      {!state ? <Loading label="결제를 확인하는 중" /> : (
        <div className={`notice ${state.ok ? 'notice--ok' : 'notice--warn'}`} role="status">{state.text}</div>
      )}
      <Link to="/billing" className="btn">요금 납부로 돌아가기</Link>
    </section>
  )
}
