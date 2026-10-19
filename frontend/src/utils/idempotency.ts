// 결제·혜택 사용처럼 "두 번 처리되면 안 되는" 요청에 붙이는 키.
// 버튼을 누를 때 한 번 만들고, 결과를 모르는 재전송에는 같은 키를 쓴다. (같은 키 + 다른 내용은 서버가 409)
export const newIdempotencyKey = (): string =>
  globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(16).slice(2)}`
