// L∞P 워드마크. ∞는 글꼴마다 모양이 달라서 SVG로 직접 그린다.
// variant="plus" → 멤버십 L∞P+, suffix → "운영" 같은 보조 표기
export function LoopMark({ className = 'logo__mark' }: { className?: string }) {
  return (
    <svg className={className} viewBox="3.4 2.6 25.2 10.8" aria-hidden="true" focusable="false">
      <path d="M16 8C13 3.2 5 3.2 5 8s8 4.8 11 0 11-4.8 11 0-8 4.8-11 0Z"
            fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinejoin="round" />
    </svg>
  )
}

interface LogoProps { variant?: 'plus'; suffix?: string; size?: 'sm' | 'md' | 'lg' }

export default function Logo({ variant, suffix, size = 'md' }: LogoProps) {
  const plus = variant === 'plus'
  return (
    <span className={`logo logo--${size}`} role="img" aria-label={plus ? '루프 플러스' : '루프'}>
      <span aria-hidden="true">L</span>
      <LoopMark />
      <span aria-hidden="true">P</span>
      {plus && <span className="logo__plus" aria-hidden="true">+</span>}
      {suffix && <span className="logo__suffix">{suffix}</span>}
    </span>
  )
}
