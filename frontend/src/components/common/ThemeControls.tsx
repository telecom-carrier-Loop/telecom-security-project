import { useTheme, type ThemePref } from '../../utils/theme'

const OPTIONS: [ThemePref, string][] = [['system', '시스템'], ['light', '라이트'], ['dark', '다크']]

// 상단 바의 해·달 버튼: 라이트 ↔ 다크 바로 전환
export function ThemeToggle() {
  const { theme, setPref } = useTheme()
  const next = theme === 'dark' ? 'light' : 'dark'
  return (
    <button type="button" className="theme-toggle" onClick={() => setPref(next)}
            aria-label={next === 'dark' ? '다크 모드로 전환' : '라이트 모드로 전환'} title={next === 'dark' ? '다크 모드' : '라이트 모드'}>
      {theme === 'dark'
        ? <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true"><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" /></svg>
        : <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true"><path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z" /></svg>}
    </button>
  )
}

// 이름 메뉴 안의 "화면 테마" (시스템 / 라이트 / 다크)
export function ThemeMenuItem() {
  const { pref, setPref } = useTheme()
  return (
    <>
      <li className="user-menu__meta">화면 테마</li>
      <li className="user-menu__theme" role="group" aria-label="화면 테마">
        {OPTIONS.map(([v, label]) => (
          <button key={v} type="button" aria-pressed={pref === v} onClick={() => setPref(v)}>{label}</button>
        ))}
      </li>
    </>
  )
}
