// 모든 API 호출은 이 함수를 거친다 (docs/contracts/api-common.md)
// - 상대 경로 /api 만 사용, 세션 쿠키(__Host-telecom_session)는 브라우저가 자동 전송
// - 상태 변경 요청에는 세션에 연결된 CSRF 토큰을 X-CSRF-Token 헤더로 붙인다
// - 공통 응답 { success, data | error, request_id } 를 풀어서 data 만 돌려주고, 실패는 ApiError

export class ApiError extends Error {
  status: number
  code: string
  details?: Record<string, string>
  requestId?: string

  constructor(status: number, code: string, message: string, details?: Record<string, string>, requestId?: string) {
    super(message)
    this.status = status
    this.code = code
    this.details = details
    this.requestId = requestId
  }
}

let csrfToken: string | null = null
export const setCsrfToken = (token: string | null) => { csrfToken = token }

interface Options {
  method?: 'GET' | 'POST' | 'PATCH' | 'PUT' | 'DELETE'
  body?: unknown
  headers?: Record<string, string>
}

interface Envelope<T> {
  success: boolean
  data?: T
  error?: { code: string; message: string; details?: Record<string, string> }
  request_id?: string
}

export async function api<T>(path: string, { method = 'GET', body, headers = {} }: Options = {}): Promise<T> {
  const finalHeaders: Record<string, string> = { Accept: 'application/json', ...headers }
  if (body !== undefined) finalHeaders['Content-Type'] = 'application/json'
  if (method !== 'GET' && csrfToken) finalHeaders['X-CSRF-Token'] = csrfToken

  let res: Response
  try {
    res = await fetch(`/api${path}`, {
      method,
      headers: finalHeaders,
      credentials: 'same-origin',
      body: body !== undefined ? JSON.stringify(body) : undefined,
    })
  } catch {
    throw new ApiError(0, 'NETWORK_ERROR', '서버에 연결할 수 없습니다. 네트워크 상태를 확인하세요.')
  }

  const payload = (await res.json().catch(() => null)) as Envelope<T> | null
  if (!res.ok || !payload?.success) {
    const err = payload?.error
    let message = err?.message ?? '요청을 처리하지 못했습니다.'
    if (res.status === 429) {
      const wait = res.headers.get('Retry-After')
      if (wait) message += ` (${Math.ceil(Number(wait) / 60)}분 후)`
    }
    throw new ApiError(res.status, err?.code ?? 'UNKNOWN', message, err?.details, payload?.request_id)
  }
  return payload.data as T
}
