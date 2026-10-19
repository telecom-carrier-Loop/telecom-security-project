import { useCallback, useEffect, useState } from 'react'
import { ApiError, api } from '../services/apiClient'

interface State<T> {
  loading: boolean
  error: ApiError | null
  data: T | null
}

// GET 요청 하나를 불러와 loading / error / data 상태로 돌려준다.
export function useApi<T>(path: string) {
  const [state, setState] = useState<State<T>>({ loading: true, error: null, data: null })
  const load = useCallback(() => {
    // 다시 불러올 때는 기존 화면을 유지한다 (처음 한 번만 로딩 표시)
    setState((s) => ({ ...s, loading: s.data === null, error: null }))
    api<T>(path)
      .then((data) => setState({ loading: false, error: null, data }))
      .catch((error: ApiError) => setState({ loading: false, error, data: null }))
  }, [path])
  useEffect(load, [load])
  return { ...state, reload: load }
}
