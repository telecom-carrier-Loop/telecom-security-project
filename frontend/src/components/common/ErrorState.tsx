import type { ApiError } from '../../services/apiClient'

export default function ErrorState({ error, onRetry }: { error: ApiError | null; onRetry?: () => void }) {
  return (
    <div className="state state--error" role="alert">
      <p>{error?.message ?? '정보를 불러오지 못했습니다.'}</p>
      {error?.requestId && <p className="muted mono">요청 ID {error.requestId}</p>}
      {onRetry && <button className="btn btn--ghost" onClick={onRetry}>다시 불러오기</button>}
    </div>
  )
}
