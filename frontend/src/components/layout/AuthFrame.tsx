import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'
import Logo from '../common/Logo'
import { ThemeToggle } from '../common/ThemeControls'

export default function AuthFrame({ children }: { children: ReactNode }) {
  return <div className="auth-page">
    <header className="auth-header"><Link to="/login" className="brand" aria-label="루프 로그인"><Logo size="lg" /></Link><ThemeToggle /></header>
    <main className="auth">
      <aside className="auth-story"><h2>연결되는 일상,<br />시작은 루프에서.</h2><p>내 요금, 내 혜택, 나의 통신 생활.<br />하나의 계정으로 편리하게 만나보세요.</p><img src="/images/brand/loop-devices.webp" width="1672" height="941" alt="" /><span>일상과 일상 사이, L∞P</span></aside>
      {children}
    </main>
    <footer className="auth-footer">L∞P는 보안 프로젝트용 가상 통신사입니다. 실제 결제·개인정보를 사용하지 않습니다.</footer>
  </div>
}
