import { useEffect, useState } from 'react'

// 화면 테마: system(기기 설정 따라감) / light / dark. 선택은 이 브라우저에만 저장한다 (계정·서버와 무관).
export type ThemePref = 'system' | 'light' | 'dark'
export type Theme = 'light' | 'dark'
const KEY = 'loop-theme'
const EVENT = 'loop-theme-change'
const media = () => window.matchMedia('(prefers-color-scheme: dark)')

export function getPref(): ThemePref {
  try {
    const v = localStorage.getItem(KEY)
    return v === 'light' || v === 'dark' ? v : 'system'
  } catch { return 'system' }
}

export const resolve = (pref: ThemePref): Theme => (pref === 'system' ? (media().matches ? 'dark' : 'light') : pref)

export function applyTheme(pref: ThemePref = getPref()) {
  const root = document.documentElement
  root.dataset.theme = resolve(pref)
  root.dataset.themePref = pref
}

export function setPref(pref: ThemePref) {
  try { pref === 'system' ? localStorage.removeItem(KEY) : localStorage.setItem(KEY, pref) } catch { /* 저장 불가 환경 */ }
  applyTheme(pref)
  window.dispatchEvent(new Event(EVENT))
}

// 컴포넌트용: 현재 선택·실제 적용 테마, 기기 설정이 바뀌면 system 일 때 따라간다
export function useTheme() {
  const [pref, setState] = useState<ThemePref>(getPref)
  const [theme, setTheme] = useState<Theme>(() => resolve(getPref()))
  useEffect(() => {
    const sync = () => { const p = getPref(); applyTheme(p); setState(p); setTheme(resolve(p)) }
    const mq = media()
    mq.addEventListener('change', sync)
    window.addEventListener(EVENT, sync)
    window.addEventListener('storage', sync)   // 다른 탭에서 바꾼 경우
    return () => { mq.removeEventListener('change', sync); window.removeEventListener(EVENT, sync); window.removeEventListener('storage', sync) }
  }, [])
  return { pref, theme, setPref }
}

// Grafana 임베드 주소에 현재 테마를 붙인다 (theme=light|dark)
export function withGrafanaTheme(url: string, theme: Theme) {
  try {
    const u = new URL(url)
    u.searchParams.set('theme', theme)
    return u.toString().replace(/kiosk=(&|$)/, 'kiosk$1')   // kiosk 는 값 없이 유지
  } catch { return url }
}
