export const won = (n: number | null | undefined) => `${Number(n ?? 0).toLocaleString('ko-KR')}원`

export const dataSize = (mb: number) => {
  if (mb < 0) return '무제한'
  return mb >= 1024 ? `${(mb / 1024).toFixed(mb % 1024 ? 1 : 0)}GB` : `${mb}MB`
}

export const shortDate = (iso: string | null | undefined) =>
  iso ? new Date(iso).toLocaleDateString('ko-KR', { month: 'long', day: 'numeric' }) : '-'

export const STATUS_LABEL: Record<string, string> = {
  OPEN: '접수', IN_PROGRESS: '처리 중', ANSWERED: '답변 완료', CLOSED: '종료',
  UNPAID: '미납', PAID: '납부 완료', OVERDUE: '연체',
  PENDING: '처리 중', SUCCEEDED: '결제 완료', FAILED: '실패', CANCELED: '취소', REFUNDED: '환불',
}

// 서버는 UTC로 주고, 화면은 한국 시간으로 보여준다
export const dateTime = (iso: string | null | undefined) =>
  iso ? new Date(iso).toLocaleString('ko-KR', {
    timeZone: 'Asia/Seoul', year: 'numeric', month: 'long', day: 'numeric', hour: '2-digit', minute: '2-digit',
  }) : '기록 없음'

export const fullDate = (iso: string | null | undefined) =>
  iso ? new Date(iso).toLocaleDateString('ko-KR', { timeZone: 'Asia/Seoul', year: 'numeric', month: 'long', day: 'numeric' }) : '-'

export const ROLE_LABEL: Record<string, string> = { CUSTOMER: '고객', ADMIN: '관리자' }

export const TICKET_STATUS: Record<string, string> = { OPEN: '접수', IN_PROGRESS: '상담 중', ANSWERED: '답변 완료', CLOSED: '종료' }
export const INCIDENT_STATUS: Record<string, string> = { OPEN: '신규', INVESTIGATING: '조사 중', RESOLVED: '해결', CLOSED: '종료' }
export const SEVERITY_LABEL: Record<string, string> = { critical: '긴급', high: '높음', medium: '보통', low: '낮음', info: '정보' }

// 표 안에서 쓰는 짧은 날짜·시간 (예: 10/20 10:21)
export const compactDateTime = (iso: string | null | undefined) =>
  iso ? new Date(iso).toLocaleString('ko-KR', {
    timeZone: 'Asia/Seoul', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false,
  }) : '-'
